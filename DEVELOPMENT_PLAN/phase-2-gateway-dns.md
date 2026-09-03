# Phase 2: Haskell Gateway Runtime and DNS Ownership

**Status**: Authoritative source
**Supersedes**: N/A
**Generated sections**: none

> **Purpose**: Capture the Haskell gateway runtime, its formal verification path, the canonical
> Route 53 ownership or update flow, and the CLI-doctrine adoption sprints that align the gateway
> daemon with [Long-Running Daemons in the Same
> Binary](../documents/engineering/README.md).

## Phase Status

✅ **Reclosed 2026-08-31 on Sprint `2.133` (Standards A/N/P).** Generation 157 reuses the exact
Generation-156 runtime identity, reads back the current Lifecycle Authority config, receives the
Provider response beyond the former generic ten-second timeout, advances through Gateway and
TLS-retention, and exits 0. Provider Worker deployment generation 4 remains Ready with zero
restarts on the exact measured envelope.

🔄 **Reopened/continues 2026-08-31 on Sprint `2.129` (Standards A/N/P).** Sprint `2.128` is Done and
live-proven: Generation 149 deploys Provider Worker generation 1 before the Gateway namespace
guardrail and crosses the registered DNS-absence boundary. Its first exact-ready Provider dispatch
then times out; Sprint `2.129` owns a closed, payload-free stage/cause classification before handler
or client behavior changes.

🔄 **Reopened 2026-08-28 on Sprint `2.108` (Standards A/N/P).** Sprint `2.107` is Done and
live-proven: generation 72 adopts the retained plan unchanged and reaches its expired deadline.
Generation 69 had durably prepared this deterministic operation but created no Job before replay
recovery refused. Sprint `2.108` renews only that exact expired prepared-but-unattested state under
CAS/read-back, while retaining the journal plan, receipts, and cursor unchanged.

✅ **Reclosed 2026-08-28 on Sprint `2.107` (Standards A/N/P).** Journal creation is absence-only;
an occupied canonical journal is validated from its own retained deadline and adopted byte-for-byte.
Generation 72 crosses the former retry-plan mismatch and reports the deliberately preserved expired
deadline, registering its separate recovery protocol below.

✅ **Reclosed 2026-08-28 on Sprint `2.106` (Standards A/N/P).** The prepared-target endpoint now
projects each of its 20 closed preparation causes without exposing private boundary detail or
changing response class or behavior. Generation 71 reports the precise journal-plan mismatch and
registers its separate correction below.

✅ **Reclosed 2026-08-28 on Sprint `2.105` (Standards A/N/P).** The finite retained replay window
now covers the complete bounded first-reconcile request envelope, migrates canonical narrower state
without deleting entries, and classifies an outer transport refusal before endpoint decoding.
Generation 70 crosses the former capacity-four boundary and reaches endpoint-owned preparation.

✅ **Reclosed 2026-08-28 on Sprint `2.104` (Standards A/N/P).** Each disposable Authority Backup
Deployment forward now acknowledges its exact IPv4/IPv6 loopback socket under a physical timeout
before HTTP starts. Generation 69 crosses the old create-before-bind exhaustion and reaches the
subsequent retained AWS-admin observation.

✅ **Reclosed 2026-08-28 on Sprint `2.103` (Standards A/N/P).** Authority Backup genesis alone
targets the exact `Recreate` Deployment while all sibling clients and steady Adapter traffic retain
their Services. Generation 68 proves the exact process is reachable through that route and
registers the separately timed child-startup handshake before behavior changes.

✅ **Reclosed 2026-08-28 on Sprint `2.102` (Standards A/N/P).** The no-wait Authority Backup
client brackets and retires one disposable forward per pending `/healthz` attempt. Generation 67
crosses the dead-child counterexample and registers the separate not-ready Service-endpoint cycle
before behavior changes.

🔄 **Reopened 2026-08-28 on Sprint `2.101` (Standards A/N/P).** Sprint `2.100` is Done and
live-proven on its token boundary: generation 65's validated 600-second request authenticates and
returns Lifecycle Authority's typed missing-generation observation. That legitimate clean-install
state exposes a separate pre-seed settings inversion: Authority Backup establishment invokes the
steady-state in-force loader before the later config-CAS step creates generation 1. Sprint `2.101`
uses the already validated Tier-0 proposal for establishment and preserves the post-CAS in-force
loader as the final readiness barrier.

🔄 **Reopened 2026-08-28 on Sprint `2.99` (Standards A/N/P).** Sprint `2.98` closes the stale
standing-role namespaces and their retained-receipt migration live. Its fresh generation-63
Authority Backup Pod authenticates to Vault, then exposes a separate genesis-order cycle: Helm
waits for credential-backed Adapter readiness before the sole establishment step can materialize
that credential. Sprint `2.99` separates pre-establishment release/listener liveness from the
post-establishment signed-store readiness gate without moving credential or S3 authority.

✅ **Reclosed 2026-08-28 on Sprint `2.97` (Standards A/N/O/P).** Lifecycle Authority readiness now
traverses exactly its signed object-store LIST and bootstrap-handoff observation; Target-worker
custody remains on the narrow worker policy and cannot re-enter the exhaustive inventory silently.
The code-owned surface is fully validated. Deployment qualification remains pending because the
first corrected rollout exposed the separate retained-failed-release retry defect registered on
the chart platform as Sprint `3.46`; no operational cutover is claimed.

🔄 **Reopened 2026-08-24; Sprint `2.97` became Active after Sprint `2.96` live-proved the
principal ordering and exposed a foreign Target-worker HMAC readiness probe (Standards A/N/P).** The clean generation-57 Pod executes the exact
diagnostic image and reports
`interpreter/initial-admission/registration-unobservable/store-http/authorization`. Sprint `2.94`
owns only a diagnostic refinement of that response's S3 error-code class before any behavior
change. Its local tests/build/lints pass, but the canonical wrapper retains an approximately
11.7-GiB conformance heap while spawning later external tools, starving the retained control plane.
Sprint `2.95` closes that gate-local lifetime correction with the exact canonical command green and
the retained control plane stable; `2.94` resumes its exact-image deployment. Execution order lives in
[README.md → Resume Here](README.md#resume-here).

✅ **Closed on its code-owned surface (2026-08-15).** Sprints `2.47` through `2.51` are all ✅ Done
on their owned Bootstrap Broker fence, attestation, checkpoint-binding, and image-identity surfaces.
The exact code-local and live-proof bounds remain in those sprint records; none is an active or
planned sprint. Landing work against a `Pending Removal` row on this closed phase is the shape
Standard I describes, not a reopen (Standard N).

**Status correction (2026-08-15, Standard C).** After Sprints `2.48` through `2.51` had closed, this
header still called `2.48` Active and `2.49` Planned and froze evidence from before `2.51`. The
phase status now derives from the sprint records below rather than restating an intermediate
checkpoint. This is the same drift class recorded by the earlier correction below, so it is
corrected in place rather than hidden by rewriting that history.

**Status correction (2026-08-14, Standard C) — the same defect this header was corrected for on
2026-08-08, recurred.** This header led with the `🔄 Reopened 2026-08-10 on Sprint 2.42` paragraph
until today, while Sprints `2.42` through `2.46` all read `✅ Done` in this file and
[README.md](README.md) had recorded the reclose on Sprint `2.45` since 2026-08-13. The header had
simply not been moved when `2.45` closed. It is corrected in place rather than rewritten, because
the 2026-08-08 correction predicted exactly this: **a status that disagrees with its own contents is
the failure mode Standard C exists to catch**, and recording that it recurred is worth more than
quietly moving the paragraph a second time. The reclose on `2.45` is restored to the record below,
where it belongs.

✅ **Reclosed 2026-08-13 on Sprint `2.45`** — the Bootstrap Broker's durable reads now have validity
predicates that can refuse. Sprint `2.46` follows on the same surface with no further reclose event:
the fence-acquire refusal now names which of its five causes fired, without publishing the owner
nonce two of them carry.

🔄 **Reopened 2026-08-10 on Sprint `2.42` (Standard A/N)** — an own-surface reopen on the Bootstrap
Broker readiness contract this phase already owns through Sprints `2.39` and `2.40`. A live
`prodbox test all --substrate aws` investigation found a Phase-`3` chart defect blocking the
broker's Kubernetes API egress; the chart caused the outage, and this phase's surface is why it cost
eight runs to find. `kubernetesObserveBootstrapLease` discards its typed transport failure with a
wildcard, so a dropped packet, a `403`, and a `404` all reach the operator as the single sentence
`Kubernetes Lease observation unavailable` while `/healthz` answers 200. That is
[chaos_hardening_doctrine.md § 23](../documents/engineering/chaos_hardening_doctrine.md) corollary 2
at the broker's Kubernetes boundary. Sprint `2.42` carries the detail through, and classifies the
underlying exception rather than showing it, because the request carries a bearer token and a
readiness body is operator-visible. No rendered manifest and no readiness verdict changes; the
Standard-P rows stay `pending`.

✅ **Reclosed 2026-08-07 on Sprint `2.41`** — Sprints `2.39`, `2.40`, and `2.41` are all Done on
their code-owned surfaces, so the 2026-08-04 reopen closes. The live reproducer and the deployed-path
readiness change remain 🧪 Standard-O and do not prevent closure.

**Status correction (2026-08-08, Standard C).** This header led with the 2026-08-04
`🔄 Active on Sprint 2.39` paragraph until 2026-08-08, while every one of this file's 41 sprint
blocks — including `2.39` itself — read `✅ Done`, and both
[README.md](README.md) and [00-overview.md](00-overview.md) had recorded the reclose on `2.41` since
2026-08-07. The phase document was the only one of the four Standard-J documents still asserting the
reopen. Nothing about the work changed; the header had simply not been moved when `2.39` closed. It
is corrected in place rather than rewritten silently, because a status that disagrees with its own
contents is the failure mode Standard C exists to catch, and this one survived two subsequent
sessions.

What that stale header asserted, and what actually became of it: the broker's `/readyz` performed a
MinIO round trip, a Vault call, and two 5-second Kubernetes reads inline in the probed request path,
measured at **5.003 s** against a 1-second probe budget while `/healthz` answered in 0.19 ms — so
the Deployment could never report available and `cluster reconcile` exited 1 before Vault was
initialized. Sprint `2.39` made the request path a constant-time projection over boundary-owned
cached facts and added `checkBrokerReadinessProjection` to hold it structurally; Sprint `2.40`
replaced the projection's unsound staleness constant with a derived bound. The broker-Pod-only
ServiceAccount-token 401 is no longer indistinguishable from "not up yet": the dependency
observation is four-valued with an absorbing identity-rejection constructor.

✅ **Reclosed 2026-08-04 on Sprint `2.38`** — own-surface reopen (Standard A) correcting the Sprint
`2.36` shutdown postcondition. The proof-carrying witness demanded an *empty* idempotency map, which
is unreachable once any request has completed (completed bindings are retained for replay), so a
graceful drain wedged permanently — and because the transaction never read the phase, a following
force-drain could not wake it. The postcondition now asks what it meant to ask: no **running** entry.
This also restores agreement with the Sprint `5.23` shutdown model, whose residue oracle counts
running waiters rather than all waiter cells. Standard-P lifecycle-orchestration surface; both rows
already `pending`.

✅ **Reclosed 2026-07-30 on Sprint `2.37`** — own-surface reopen (Standard A) making the emitter
retained-assertion (unacked-suffix) leak class non-constructible, with a failed-checkpoint
recompaction liveness fix. Byte-compatible; no durable-format change and no runtime selector.
The prior reclose on Sprint `2.36` below stands unchanged.

✅ **Reclosed 2026-07-27 on Sprint `2.36` (own Bootstrap Broker runtime surface).** A full-unit
contention run falsified the Sprint `2.33` forced-drain closure: the manager can discard a timed-out
worker cancellation and publish `BrokerStopped` while a replay worker remains blocked on its
completion cell. The later `BlockedIndefinitelyOnSTM` is consistent with that leaked ownership.
Sprint `2.36` replaces the timeout-discarding terminal transition with proof-carrying terminal
shutdown and keeps timeout as `ShutdownIncomplete`, never as evidence of `Stopped`. Historical
Sprint `2.33` results remain Done on route/config/custody scope; its shutdown claim is superseded.

✅ **Expanded 2026-07-12 with the Foundation Epoch's phase-2 slice; that slice is complete.**
Sprint `2.34` (Done 2026-07-12;
registered by governance Sprint `0.17` in
[phase-0-planning-documentation.md](phase-0-planning-documentation.md) for counterexample
`LCPC-2026-07-11`, mechanism `F-READY`) added the compiled service boundary and readiness
surface: a closed `GatewayRoute` registry as the one place any daemon path string exists, with the
dispatcher, clients, chart probe rendering, and the `ObjectStore`/`TargetSecret` wire paths as
projections; one pure readiness projection (`computeReadiness`) over drain, emitter authority, and
worker facts; and a `GatewayChartStatics` record
feeding the deployed values and the generated port/identity sections with a forbidden-literal chart
lint and a deployed-values-equal-compiled conformance gate. It absorbs the exact-readiness-evidence
deliverable rescoped out of Sprint `1.61` (see
[phase-1-runtime-cli-aws-foundations.md](phase-1-runtime-cli-aws-foundations.md)). Phase `2` has no
remaining Foundation-Epoch work: Sprint `2.34` is complete, Sprint `2.32` subsequently landed its
current-authority refinement, and the still-active Foundation-Epoch sprints in other phases retain
their own status without creating a Phase-2 blocker.

✅ **Certificate-scope tail complete 2026-07-20 (Sprint `2.35`).** Governance Sprint `0.18` in
[phase-0-planning-documentation.md](phase-0-planning-documentation.md) registered the pure
`CertScope` algebra, Tier-0 scope config, fail-fast bound-host validation, derived public-edge
`Certificate.spec.dnsNames`, exact canonical scope-set retention coordinate, and fail-closed
certificate-expiry status rungs. Each substrate binds its explicit served hostname to the configured
scope set; wildcard SANs do not synthesize listeners, routes, or DNS records. Retention and restore
use only the exact canonical SAN set because cert-manager treats any changed `dnsNames` set as a new
issuance specification; `impliedBy` remains the coverage/admission order. The live serving proof is
the now-unblocked Sprint `5.22` in
[phase-5-canonical-test-suite.md](phase-5-canonical-test-suite.md), so deployment qualification
remains pending without reopening this code-owned sprint.

✅ **Historical reclosure 2026-07-21 on Sprint `2.33`; superseded by Sprint `2.36`.** Sprint
`2.33` extracts pre-Vault recovery into a minimal Bootstrap Broker: a closed `RuntimeRole` split
(`src/Prodbox/Runtime/Role.hs`) where the `bootstrap-broker` and `gateway-runtime` roles each decode
only their own mounted Dhall; a closed `BrokerRoute` registry limited to bounded
init/unseal/seal/status/rotation, allowlisted baseline reconcile, bounded PKI status/test-issuance,
and child custody/recovery — with no generic KV, mesh, DNS, Pulumi, SES, authority-CAS, or
target-secret route; the prepared-init PGP-recovery/password-AEAD custody protocol (burn-recipient
initial token never decrypted; separately generated accessor-audited short-lived root session
revoked and proven absent) with a full crash/resume matrix; the child-Vault
journal→parent-custody→acknowledged-delete delivery protocol; loopback-restricted authenticated
Service with bounded bodies, absolute deadlines, idempotency, redaction, and drain; removal of the
pre-Vault handlers from `Gateway/Daemon.hs`/`Gateway/Client.hs`; and a `checkBootstrapBrokerIsolation`
lint proving the Gateway registry carries no bootstrap route or credential. Post-unseal handoff is an
observed state transition, not the broker becoming the post-Vault Lifecycle Authority. Standard P
keeps the public production gateway wrapper on the mutually exclusive `LegacyModelBEmitter` rollback
topology (Sprint `2.32`) until current-revision qualification and later cutover; no dual writer or
production cutover is claimed. Sprint `3.26` later supplied the chart/render foundations for
physically separate roles, but did not activate that topology; current activation and removal are
governed by the [plan status](README.md#resume-here). Historical Sprint `2.31` remains Done
for its bounded-state result.

✅ **Sprint `2.32` code-owned target complete 2026-07-20.** The additive, mutually exclusive
`JournalLeaseEmitter` topology replaces the global child-process permit and interleavable continuity
loops with one bounded single-writer actor per emitter, an encrypted identity-bound retained
journal, journal-first admission, exact recovery, and a current Lease/incarnation witness. Target
readiness clears on Lease loss and returns only after reacquisition and recovery. Standard P keeps
the public production wrapper on the mutually exclusive `LegacyModelBEmitter` rollback topology until
current-revision qualification and later cutover; no dual writer or production cutover is claimed.

✅ **Reclosed 2026-07-10 on bounded gateway execution.** Sprint `2.31` replaces the
uptime-growing append-log/full-retransmission path with bounded semantic state, signed
cursor/delta/checkpoint repair, fixed retention, early frame admission, process-wide frame permits,
and a capacity-one child schedule. Per-emitter Model-B continuity stages and re-observes the exact
signed assertion/next anchor before publication, while the durable Vault admission marker prevents
lost continuity from resetting an emitter. `DnsWriteAction` binds validated record inputs, the
current claim, deterministic credential generation, and a same-lease re-observed continuity fence
inside a sealed AWS environment. Pure/property, Model-B, loopback daemon, native partition,
profiling, and finite TLC proofs close the code-owned surface; the deployed restart-free soak stays
the non-blocking Sprint `5.16` live-proof axis.

**Reopen cause (2026-07-10).** The live suite falsified the implicit
runtime-refinement assumption behind the current peer log: the three gateway containers repeatedly
reached the enforced `512Mi` cgroup limit while their Deployments later returned to
`Available=True`. The then-current daemon appended unique heartbeat events forever, retransmitted
the full log to every peer, and admitted unbounded request/rejection materialization. Sprint `2.31`
owns the bounded replacement above. Earlier gateway, DNS, CBOR, federation, and Vault-role closures
remain valid.

✅ **Reclosed 2026-07-10 for the gateway-daemon Vault-role SSoT.** Sprint `2.30` is Done on its
Phase-2-owned gateway/Vault-identity surface. `Prodbox.Vault.RoleId` owns the closed `VaultRoleId`
inventory and its `vaultRoleIdText` projection; the supported generated ChartPlatform gateway
release values and `Vault/Reconcile` role spec both consume `VaultRoleGatewayDaemon`. The role binds
exactly `prodbox-gateway` and `gateway-gateway`. Unit tests prove that exact policy set, decode the
actual generated AWS gateway release values and compare `vault.role` with the typed projection, and
guard `ChartPlatform.hs` against a duplicated role-name literal. `charts/gateway/values.yaml` retains
the same role name as its documented chart default; the supported generated render supplies the
typed value, and this closure does not claim that every gateway configuration surface is typed.
Validation: `./.build/prodbox test unit` (1260/1260) and `./.build/prodbox dev check` (exit 0). All
earlier Phase `2` closures remain valid.

✅ **Reclosed 2026-07-05 for the daemon-mediated post-bootstrap boundary.** Sprint `2.29` is now
Done on its code-owned surface: the daemon has a pre-Vault config loader that binds diagnostics and
`POST /v1/bootstrap/vault/ensure` before Vault-backed event keys, AWS credentials, or MinIO
credentials resolve; the endpoint enforces a bounded redacted request with loopback proof, reaches
MinIO/Vault over in-cluster Service DNS, performs init/unseal/reconcile with no standing unseal
authority, and exposes a host-side `Prodbox.Gateway.Client.ensureVaultBootstrap` call for later
lifecycle routing. Validation: `cabal build --builddir=.build exe:prodbox`,
`./.build/prodbox test unit` (1178/1178), and
`cabal test --builddir=.build prodbox-daemon-lifecycle --test-options=--hide-successes` (12/12).
Sprints `4.42`, `5.14`, and `7.30` consume this endpoint to remove the remaining direct host
MinIO/Vault transports. All previously closed gateway runtime, DNS, CBOR, and federation surfaces
remain `Done` on their owned validation axes.

✅ **Live-proven 2026-06-26 — the gateway integration validations now pass under the green home
`test all`.** The `gateway-daemon`, `gateway-pods`, and `gateway-partition` named validations —
previously the operator-driven `🧪 Live-proof: pending` axis (a running cluster is required, see below)
— all pass `ExitSuccess` in the green home `prodbox test all` (2026-06-26, 18/18; see
[00-overview.md → Historical Alignment Record](00-overview.md#historical-alignment-record)). Phase 2's gateway-runtime + DNS-ownership surfaces
are thereby home-substrate live-proven (this run also corrected the `gateway-daemon` validation's
`config.dhall` renderer — empty `event_keys`, `vault = None`, `SecretRef`-typed creds — so the host
`gateway status` decodes and queries the live daemon; recorded in [README.md](README.md) Closure
Status). The `--substrate aws` partition-tolerance axis stays a distinct, non-blocking live-infra note
([substrates.md](substrates.md)).

✅ **Reclosed 2026-06-16** — the Vault-root finalization (see [README.md → Historical Closure Record](README.md#historical-closure-record),
2026-06-14, [vault_doctrine.md](../documents/engineering/vault_doctrine.md), and
[cluster_federation_doctrine.md](../documents/engineering/cluster_federation_doctrine.md)) makes
prodbox manage a hierarchy of clusters whose trust and unseal authority form a Vault transit-seal
tree: a root cluster's Vault is Shamir-sealed and unsealed only by the operator, and each downstream
child cluster auto-unseals against its parent's Vault, which also custodies the child's init keys.
A cluster's knowledge of its downstream clusters — their existence, identities, endpoints,
kubeconfigs, account ids, and Pulumi stacks — is secret data legible only behind an unsealed Vault.
This reopens Phase `2` to own the gateway/CLI federation-trust surface that did not exist when the
phase last closed. Sprint `2.26` is now ✅ Done: the typed custody foundation, direct parent-side
live registration path, gateway-mediated child-listing / bootstrap-reference endpoints, and full
downstream-inventory metadata shape are landed and validated. The 2026-06-15 Model-B + whole-system
zero-child-info refinement (see the 2026-06-15 entry in the
[Historical Closure Record](README.md#historical-closure-record) and
[vault_doctrine.md §9](../documents/engineering/vault_doctrine.md)) extends Sprint `2.26`'s custody
surface with the downstream-identity-to-Vault-KV + opaque-namespace deliverable: downstream identity
rides the Model-B object-store as `DownstreamCluster <id>` logical objects, and per-child Kubernetes
namespaces are opaque IDs, so a sealed-parent Kubernetes dump leaks no child name — refines, does not
reverse, the 2026-06-14 model and reopens no new phase. **Prior closure preserved**: ✅ Done on the
code-owned gateway-runtime, DNS-ownership, peer-transport, and daemon-lifecycle surfaces
(Sprints `2.1`–`2.25`); the reclosure detail below is retained verbatim and is unchanged by this
reopen.

✅ **Reclosed on the code-owned surface 2026-06-09** — reopened 2026-06-09 for Sprints `2.24`–`2.25`
(design-intention review; see [README.md → Historical Closure Record](README.md#historical-closure-record)); both have now landed. Sprint
`2.24` ✅ deleted the daemon/workload `--log-level` / `--port` / `--foreground` override flags + their
threading (the pending Sprint 2.20 ledger removal; the daemon now sources log-level from Dhall and
the REST port from Orders). Sprint `2.25` ✅ hardened the gateway runtime — per-connection `withAsync`
with a bounded read timeout on both listeners, an inbound-vs-outbound peer-health split, one
canonical base64url event-key encoding, a derive-context `decode . encode == id` round-trip,
**restart-based Orders promotion** with the dead `orders_promoted` machinery deleted (D4:
`stateOrdersVersionUtc` never advances in-process; the refuse-to-reclaim-while-behind gate kept), the
`markEventProcessed` IS-NULL guard restored, and the topology-honest fault-model reframe (home =
three logical ranked peers on one physical host under shared fate; independent host-failure
tolerance is the AWS / future-multi-host capability). Validation at reclosure: `check-code` 0, `test unit` 760,
`integration cli` 35, `prodbox-daemon-lifecycle` 14/14, `lint docs` 0, `docs check` 0. At that
reclosure the live `gateway-daemon`/`gateway-pods`/`gateway-partition` validations were still
operator-driven; the 2026-06-26 run above subsequently proved them. **Prior closure preserved**: ✅
Done (Sprints `2.1`–`2.16` + `2.17` +
`2.18` + `2.19` + `2.20` + `2.21` + `2.22`, with Sprint `2.21` closed via the live home-substrate
file-watch exercise 2026-06-02; Sprint `2.23` subsequently closed the drain-completion
cancellation-propagation residual). The prior closure detail below is retained as history.

✅ **Done** — Sprints `2.1`–`2.8` remain `Done` on the gateway runtime, Route 53 ownership,
peer-transport, claim/yield, time-base, Orders-promotion, and host-info cleanup surfaces. The
phase is reopened by Sprint 0.2 to schedule Sprints `2.9`–`2.16`, which adopt the long-running
daemon discipline from [the engineering doctrine docs](../documents/engineering/README.md): the explicit
`load→prereq→acquire→ready→serve→drain→exit` lifecycle with worker loops wrapped in
`try`/`catch` plus bounded retry-with-backoff, `/healthz` / `/readyz` / `/metrics` endpoints
with golden-captured response shapes, the `BootConfig` / `LiveConfig` split with `SIGHUP` hot
reload and atomic-swap discipline on `envLiveConfig` (the reload trigger is reopened by
Sprints 2.20/2.21 under the pure-Dhall config doctrine — see
[config_doctrine.md](../documents/engineering/config_doctrine.md) — and becomes a
file-watch worker on the mounted Dhall path, with boot-field changes draining and exiting
so the kubelet restarts the Pod), `co-log` structured JSON logging, test
hooks in `Env`, the `prodbox-daemon-lifecycle` test stanza asserting that single SIGTERM
begins drain and second SIGTERM (or drain deadline) forces exit, the daemon CLI plumbing
(`--config <path>` is the sole startup knob under the new doctrine; `--log-level`, `--port`,
`--foreground`, and `PRODBOX_*` env-var precedence are forbidden — see
[config_doctrine.md §10](../documents/engineering/config_doctrine.md#10-forbidden-surfaces)),
and the formal at-least-once event-processing module
(`src/Prodbox/Daemon/Events.hs`) introduced in Sprint `2.16`. Sprint 0.3 extends the
deliverable lists of Sprints `2.9`–`2.12` with the doctrine items surfaced by the May 2026
audit: the default 30 s drain deadline plus explicit `bracketOnError` for resources with
external side effects (2.9), the `envMetrics :: MetricsRegistry` typed daemon `Env` field
backing `/metrics` (2.10), the STM broadcast channel for `LiveConfig` subscribers plus the
prescribed on-disk Dhall file shape with top-level `schemaVersion` / `boot` / `live`
records (2.11), and the daemon log level
refreshed from `LiveConfig` on every hot reload (2.12). Current worktree evidence now puts
Sprints `2.9`–`2.16` in `Done` state: the gateway daemon launches from one structured async
entrypoint with bounded drain and endpoint coverage, acquire gating flows through the prerequisite
registry, live config reloads use the structured `schemaVersion` / `boot` / `live` shape with an
STM broadcast, production hooks stay no-op by default, and the daemon-lifecycle stanza covers
readiness, health, metrics, graceful drain, and forced drain behavior.

## Phase Summary

This phase owns the Haskell gateway daemon, DNS inspection command, the pre-Vault daemon bootstrap
REST surface, and related command surfaces, preserves the formal model entrypoint, and keeps Route
53 write ownership inside the in-cluster gateway workload. It owns the gateway image packaging
contract, in-cluster-registry-backed image delivery for the gateway workload, DNS inspection, and the TLA+
entrypoint. The landed phase-owned surfaces include the daemon, `prodbox gateway status`, bounded
`/v1/state` diagnostics, bounded Orders admission, runtime-to-model correspondence notes,
per-emitter cursor/delta transport with signed semantic repair, runtime claim/yield emission under
`CanWriteDns`, bounded-clock-skew enforcement, and Orders-version coordination. The hot semantic
projection, replay evidence, parser/frame admission, peer cursors, and diagnostic hashes all have
finite limits independent of daemon uptime. The code-owned target topology adds one bounded
single-writer emitter actor, an encrypted identity-bound retained journal, journal-first admission,
an OS-lock plus Lease/incarnation fence, exact recovery, bounded acknowledgement/checkpoint repair,
operation-specific lanes, and native Route 53 calls. Its typed persistence projection describes the
stable identity, retained home and AWS claims, and exact Lease RBAC. Phase 3 supplied the physical
rendering foundation; production adoption remains plan-tracked. Standard P keeps the public production wrapper
on the process-construction-exclusive `LegacyModelBEmitter` rollback topology, including its
capacity-one child schedule and AWS CLI Route 53 path, until current-revision qualification and
later cutover; there is no runtime selector or dual writer. The gateway container doctrine is
implemented on `ubuntu:24.04` with in-image `ghcup`, pinned GHC `9.12.4`, no symlinked Haskell tool
shims, and the retained in-image AWS CLI rollback bundle. Sprints
`2.1` through `2.7` now remain closed on the gateway-daemon, native partition validation split,
single-record Route 53 doctrine, peer-transport runtime closure, claim/yield emission under
`CanWriteDns`, time-base discipline, and Orders-promotion coordination. Sprint `2.8` is now
closed as the cleanup follow-up that removed the retained legacy `NTP synchronized` timedatectl
parser branch from `src/Prodbox/Host.hs`, so the supported host doctrine closes only on Ubuntu
24.04's `System clock synchronized: yes/no` field. This phase does not own the Kubernetes Gateway
API or Envoy Gateway public edge; those surfaces remain in Phases `1`, `3`, `4`, and `5`.

**Independent Validation** (Standard N — see
[development_plan_standards.md](development_plan_standards.md) Standards N/O): this phase is
validatable in full on its owned surface — the Haskell gateway daemon runtime, peer transport,
DNS-write-gate logic, claim/yield protocol, Orders-promotion coordination, Vault/object-store
endpoints, and the formal TLA+ entrypoint — with no dependency on any later phase. The code-owned
surface closes on local validation (`prodbox dev check`, `prodbox test unit`,
`prodbox test integration cli`/`env`, the `prodbox-daemon-lifecycle` stanza, and `prodbox dev tla-check`)
for the previously landed surface; Sprint `2.31` adds its bounded-state and transport proofs, while
Sprint `2.32` adds actor, journal, Lease/incarnation, recovery, native Route 53, and finite-state
protocol proofs;
where a validation would touch Route 53, a deployed cluster, an unsealed Vault, or running MinIO,
it is exercised on the home/local substrate or against a stub, and the live-infrastructure exercise
is tracked as a non-blocking `Live-proof: pending` note rather than as `⏸️ Blocked`. Live AWS or
deployed-cluster proof never becomes a backward dependency; a demonstrated defect in this phase's
own runtime, such as the July 10 unbounded-memory counterexample, does reopen the owned surface.

**What the `gateway-partition` validation establishes (Standard C, recorded 2026-08-11).** Eight
sprints in this document cite `prodbox test integration gateway-partition` as a numbered validation
step — `2.2`, `2.3`, `2.4`, `2.5`, `2.7`, `2.25`, `2.31`, and `2.32`. Read those citations with this
scope, stated once here rather than repeated in each (§ 1 of
[documentation_standards.md](../documents/documentation_standards.md) — a fact derivable from one
place is not copied):

- It **is** a genuine property test over the real `GatewayState` folds, and its `-> []` prerequisite
  registration was honest: it runs wholly in process, with no peer, no cluster, and no harness.
- It **does not** observe a partition, a restart, a peer response, or a takeover. Its emitted
  `INITIAL_OWNER_ACTIVE=true`, `PARTITION_TAKEOVER_ACCEPTED=1`, `SINGLE_WRITER_AFTER_TAKEOVER=true`,
  `EMITTER_PIPELINE_COMPOSED`, and `OFFLINE_REPAIR_EXACT` lines were **string literals**, not
  rendered verdicts, so a citation of one of those tokens is evidence that the pure fold composes —
  not that the deployed runtime survived the named fault.

Neither the sprints' code deliverables nor their other validation steps are withdrawn.

**Resolved by Sprint `5.33` ✅ (2026-08-11)** in
[phase-5-canonical-test-suite.md](phase-5-canonical-test-suite.md): the emitted values are rendered
from the computed report, and the node has **left the integration surface entirely** — it is no
longer a `prodbox test integration` verb, no longer a member of `canonicalNativeValidations`, and
runs in the unit suite, where its identity as an in-process property test is accurate. Every
citation of `prodbox test integration gateway-partition` as a numbered validation step in the
sprints named above is therefore a citation of a command that no longer exists; read each as
evidence that the pure fold composes, which is what it always was and is now the only thing it
claims. The unit suite pins the same properties plus one the node could not previously have: that
its emitted lines change when its composition changes.

## Current Baseline In Worktree

- `src/Prodbox/Gateway.hs` owns the public `prodbox gateway start|status|config-gen` entry
  surfaces. `gateway start` runs through the native Haskell daemon runtime in
  `src/Prodbox/Gateway/Daemon.hs` and `src/Prodbox/Gateway/Types.hs`. All Python gateway code has
  been removed.
- The gateway image is built from the single union runtime Dockerfile `docker/prodbox.Dockerfile`
  (consolidated from the former `docker/gateway.Dockerfile` by Sprint `1.45`; the gateway role is
  selected by the chart's `gateway start` `args:`). It is single-stage `ubuntu:24.04`, installs
  `ghcup` in-image, pins GHC `9.12.4`, retains `tini` as PID 1 and the official AWS CLI bundle per
  native Debian host architecture, and does not depend on the old mounted `haskell:9.6.7-slim`
  toolchain context or symlinked GHC tool shims.
- The in-cluster gateway steady state is repo-rootless: `app/prodbox/Main.hs` permits repo-rootless
  `gateway start|status`, and `charts/gateway/` supplies typed `SecretRef.Vault` references that the
  daemon resolves through Vault Kubernetes auth. Sprint `3.25` subsequently bound chart liveness
  to `/healthz` and readiness to `/readyz`; `/v1/state` remains operator diagnostics only.
- `src/Prodbox/Gateway.hs` queries daemon state over `/v1/state`, matching the in-pod REST listener
  in `src/Prodbox/Gateway/Daemon.hs`. The response exposes finite semantic/replay counts, a
  fixed-capacity recent-assertion hash tail, bounded per-peer/per-emitter receive cursors, and the
  already-observed continuity disposition. It does not expose a process-lifetime event total or
  traverse an append-only history.
- `src/Prodbox/Gateway/Types.hs` now enforces the documented cross-field interval relationships
  from `documents/engineering/distributed_gateway_architecture.md` against the Orders timeout.
- `src/Prodbox/Gateway/Types.hs` parses certificate, key, CA, and socket metadata in the daemon
  config and Orders document. `src/Prodbox/Gateway/Bounds.hs`, `State.hs`, `Orders.hs`, and
  `Peer.hs` admit only finite membership/field/frame inputs, fold signed assertions into keyed
  latest-heartbeat/ownership state, and exchange bounded per-emitter deltas. A receiver that falls
  behind the replay checkpoint receives a signed compact heartbeat/ownership snapshot plus a
  bounded contiguous suffix; duplicates and reordering cannot grow the projection. The daemon
  updates inbound heartbeat observations, rejects excessive clock skew or stale Orders, validates
  retained certificate/key/CA material, and binds the REST and peer listeners on the configured
  local Orders hosts.
- `src/Prodbox/Gateway/Continuity.hs` and `ContinuityStore.hs` implement per-emitter Model-B
  continuity at `continuity/<emitter>`. Each record contains one committed fixed-width
  epoch/sequence/digest anchor and at most one exact staged signed assertion with its next anchor.
  The retained record preserves safe emission continuity across total peer restart; current peer
  semantic evidence is repaired by bounded peer snapshots after restart rather than claimed to be
  persisted in the continuity record. Vault KV
  `secret/prodbox/gateway/continuity-admission/<node>` records one-time admission, so a previously admitted
  emitter with a missing, corrupt, or unobservable continuity object stays emission/claim/DNS
  disabled.
- `src/Prodbox/Gateway/DnsAuthority.hs` binds validated record inputs, the active claim,
  deterministic credential generation, and the re-observed continuity fence into `DnsWriteAction`.
  `src/Prodbox/Gateway/ChildSchedule.hs` serializes every gateway object-store, Vault, public-IP,
  and Route 53 child through Sprint `1.60`'s capacity-one schedule and bounded deadline.
- The Haskell `prodbox gateway ...` surface remains distinct from the Envoy Gateway public edge
  surface.
- `src/Prodbox/Dns.hs` owns the public `prodbox dns check` surface. All Python DNS wrappers have
  been removed.
- `src/Prodbox/Tla.hs` owns the public `prodbox dev tla-check` surface. All Python TLA+ wrappers have
  been removed.
- The DNS surfaces now close on one canonical public hostname, `test.resolvefintech.com`, and one
  Route 53 record without changing the separate Haskell gateway-daemon boundary.
- Gateway parser, renderer, and CLI proof live in the Haskell test suites under `test/`, while
  the TLA+ artifacts live under `documents/engineering/tla/` and are exercised through
  `prodbox dev tla-check`.
- `src/Prodbox/TestPlan.hs` maps the gateway validation names into Haskell-owned validation
  entrypoints in `src/Prodbox/TestValidation.hs`, and `gateway-partition` now runs as a distinct
  native partition scenario with explicit bounded-delta idempotency and single-writer/rejoin report
  markers instead of delegating to `tla-check`.
- `src/Prodbox/Host.hs` now accepts only the supported `System clock synchronized` timedatectl
  field in `parseTimedatectlNtpDisposition`, so the Phase `2` host-info path closes on the Ubuntu
  24.04 field format named by the current doctrine.
- The canonical closure gates for this phase are `prodbox dns check`, the named gateway
  integration validations, and `prodbox dev tla-check`.

## Sprint 2.1: Haskell Gateway Runtime and Command Surface [✅ Done]

**Status**: Done
**Implementation**: `src/Prodbox/Dns.hs`, `src/Prodbox/Gateway.hs`, `src/Prodbox/Gateway/Daemon.hs`, `src/Prodbox/Gateway/Types.hs`, `charts/gateway/`, `docker/prodbox.Dockerfile`, `test/unit/Main.hs`, `test/integration/CliSuite.hs`
**Independent Validation**: native parser/renderer and bounded daemon tests, the built CLI suite,
and the home/local gateway validations exercise this command/runtime surface without any later
phase; live infrastructure remains an orthogonal Standard-O axis.
**Docs to update**: `documents/engineering/cli_command_surface.md`, `documents/engineering/dependency_management.md`, `documents/engineering/distributed_gateway_architecture.md`, `documents/engineering/local_registry_pipeline.md`, `documents/engineering/unit_testing_policy.md`

### Objective

Keep the gateway daemon, DNS inspection command, and gateway-adjacent CLI surfaces on Haskell
while preserving the implemented runtime contract and container doctrine.

### The defect Sprint `2.47` introduced, and why its live proof still passed

**`2.48`'s fix re-broke `2.47`'s retirement, and saying so plainly is the point of this section.**
Sprint `2.47`'s live proof retired six fence generations on the operator host. Every one of those
retirements saw `BootstrapLeaseMissing`, because the Lease had never been creatable — which is
exactly what `2.48` then fixed. The moment a Lease existed, retirement began refusing
`BootstrapFenceRetireLeaseStillLive` against a Lease that had expired **1h44m earlier**:

```text
renewTime = 2026-08-14T21:39:44Z   leaseDurationSeconds = 300   now = 23:29:21Z
```

**The mechanism is an ordering hazard in `retireExpiredPredecessor`, and it is `2.47`'s own code.**
`bootstrapLeaseFromResponse` encodes an already-expired Lease as
`deadlineFromInstant monotonicBeforeWall` — a deadline *at the instant the observation was taken* —
and `deadlineExpired now limit` is `now >= limit`. `2.47` sampled its monotonic instant **before**
issuing the observation, which guarantees `now < monotonicBeforeWall`, so an arbitrarily stale Lease
reads as live and the fence can never be retired. The host was wedged again, for a new reason.

Fixed by sampling the clock after the observations. More elapsed time is strictly safer for the
instant's other two uses — the request deadline and the predecessor's expiry both only become more
certain — so the ordering has one correct direction and no trade-off.

**Two things this is evidence for.** First, the retirement is not merely a happy path: it fired
against a *present* Lease only after this fix, retiring generation 7 on the live host. Second, and
more usefully, **a live proof is only as strong as the states it actually reached** — `2.47`'s proof
was real, and it could not have exercised this arm, because the arm did not exist until another
sprint landed. That is recorded here rather than as a correction to `2.47`, because nothing `2.47`
claimed was false; its coverage was bounded in a way nobody could state at the time.

### The fourth instance of one defect class, and the widest

With the fence and Lease clear, the refusal became `EngineSecretWorkerRefused` — one word for a
**twenty-constructor** `EngineSecretWorkerError`. A permit deadline that elapsed, a checkpoint
read-back mismatch, an attestation refusal, and a cleanup refusal were indistinguishable. Named to
the nested constructor under the rule `2.46` established, which this session has now applied at four
depths: five acquire refusals, six Lease refusals, the status code inside the non-success arm, and
now twenty secret-worker causes.

### Deliverables

- `prodbox gateway start|status|config-gen` and `prodbox dns check` are implemented in Haskell.
- The in-cluster gateway container runs the Haskell binary from a single-stage `ubuntu:24.04`
  image built from the union runtime `docker/prodbox.Dockerfile`, with in-image `ghcup` pinned to GHC `9.12.4`,
  no symlinked Haskell tool shims, and the official AWS CLI bundle per native Debian host
  architecture.
- Gateway image delivery uses the single-binary in-cluster `registry:2` service as the only
  supported steady-state cluster image source. Its retained namespace/front-door naming may still
  say `harbor`, but no Harbor product or UI is present.
- Gateway image publication follows the lifecycle-owned native-host-architecture doctrine:
  `amd64` hosts publish `amd64` images, and `arm64` hosts publish `arm64` images.
- Gateway event-key continuity and state inspection move to Haskell-owned modules.
- The daemon and `prodbox gateway status` share one native `/v1/state` transport whose retained
  state, computation, and output are bounded independently of uptime by Sprint `2.31`.
- Native gateway config parsing enforces the documented cross-field gateway-interval relationships.
- The target steady state remains the in-cluster gateway workload; no host-side daemon is revived.

### Pre-Target Cleanup-Continuation Local Checkpoint (2026-08-29)

The exact later-journal refinement now selects one closed cleanup-only continuation rather than a
no-effect renewal. The accepted set is exhaustive: remint intent, create-attempt prepared, key
created, cleanup required, or cleanup proven, with both recovery flags where the journal phase
carries one. Target committed, complete, embedded-permit mismatch, invalid bytes, and every
unobservable observation remain refusals. Job and Pod must still be positively absent.

The opaque recovery proof binds a normal-worker replacement kind to the SHA-256 digest of the exact
predecessor signed permit. The old journal remains at its permit-derived coordinate; the successor
therefore initializes a distinct journal at `cleanup-required/initial-attempt`. The existing
execution fold deletes the deterministic bounded key family and commits stable absence before it
can advance to `intent-committed/remint-used` and prepare one create attempt. Direct restart before
cleanup, a normal unbound replacement, a cleanup kind under no-effect proof, predecessor
substitution, and Target-committed/complete recovery all refuse. Prepared-target outbox replay
retains the same predecessor digest across a response-lost or later expired renewal.

Focused Sprint-2.116 passes **10/10**, the exact AWS-admin Authority group passes **38/38**, all
**4727/4727** primary cases and the **27/33/31** auxiliary authority suites pass. Fourmolu is
applied, HLint reports `No hints`, documentation/diff checks pass, and the warning-clean all-target
canonical `prodbox dev check` exits 0 after 10:24.16. Binary
`sha256:d77698098ca8f33dc984bf4a0555fee3e230cceaed2c5694be1fd330259c5ea2` is the
Generation-107 qualification input and is byte-identical to the gate-built executable. Deployment
qualification remains outstanding; the next supported reconcile must preserve the Generation-106
predecessor journal, prove cleanup before mint, and register its exact terminal observation.

### Generation-107 Mode-Indexed Cleanup-Permit Counterexample (2026-08-29)

Generation 107 builds local image
`sha256:c7862bbaff130c327bf0be65214e39e5ff09842bee49a431793b5fa52afd0bbf` in 994.0 seconds,
publishes registry manifest
`sha256:26f7e3c1b2731cdf88baf07d5badc530ebcda9bf8d592446faac3048dc73ac02`, and completes the
281.6-second containerd import at OCI manifest
`sha256:7867708c7d1f8d4266f022b2e008493554585e52b74f43502f21449e585d2719`. Baseline
reconciliation retains root session `root-session-3b9d5743…` and read-back digest `a5756119…`.
The exact-image Authority and Target Agent are Ready with zero restarts; no credential worker Job
or Pod exists. The protected log again proves
`present/key-created/remint-used`, but preparation refuses before worker creation at
`recovery-intent-rejected`; the supported command exits 1 after 32:44.77.

Stable counterexample `AWS-ADMIN-CLEANUP-RECOVERY-PERMIT-KIND-REJECTED-2026-08-29` proves the
cleanup proof belongs to the mode-indexed Authority-backup genesis program while the new cleanup
kind admits only normal operator-material drafts. It licenses extending the same predecessor-bound,
cleanup-before-remint encoding to the already closed Genesis permit family while retaining the
normal family. Backup repair is not an expired-Authorized renewal program and stays
unrepresentable. The counterexample does not license changing the underlying program, treating
Genesis as normal, dropping the Genesis binding, or widening the accepted journal phases.

### Mode-Indexed Cleanup-Permit Local Checkpoint (2026-08-29)

`CleanupRecoveryKind` now carries a closed `NormalOperatorMaterialCleanupProgram` or
`GenesisBackupCleanupProgram` plus the digest of the exact predecessor signed permit. Genesis
canonicalization retains its target binding; normal retains its operator-material family. The
Authority renewal, signed-permit wire, existential decoder, prepared-target projection, Kubernetes
rendering, worker mode selection, and new-journal initialization all preserve that family. Backup
repair remains admitted only from `BackupRepairFrozen` and cannot enter expired-Authorized
recovery. Cross-family substitution, predecessor substitution, a cleanup kind under a no-effect
proof, and mint-before-cleanup remain refused.

Focused Sprint-2.116 passes **11/11**, the exact AWS-admin Authority group passes **39/39**, all
**4728/4728** primary cases and the **27/33/31** auxiliary authority suites pass. Fourmolu is
applied, HLint reports `No hints`, documentation/diff checks pass, and the warning-clean all-target
canonical `prodbox dev check` exits 0 after 9:06.50. Binary
`sha256:f85a5338c33c5c8be1276163d5f867a9451e6c28a6ea200388ed665b21501082` is the
Generation-108 qualification input and is byte-identical to the gate-built executable. Deployment
qualification remains outstanding; the next supported reconcile must bind the Generation-106
Genesis predecessor, prove cleanup before mint, and register its exact terminal observation.

### Generation-108 Cleanup-Remint Counterexample (2026-08-29)

Generation 108 builds local image
`sha256:83c3fbf9a806e350ea89e3f6dc744b4e5b62590187dc58f6ca8f167c3dc69370` in 996.4 seconds,
publishes registry manifest
`sha256:8a21c7f6e3ecaecc9e44da87a18e95a6a50ee19a41887508876973d0448b3295`, and completes the
284.3-second containerd import at OCI manifest
`sha256:28e9fff5076f8be3e8d1f5e8bcb7f370b734fcaefd5cdfe8fef26d742c45aa7d`. Baseline
reconciliation retains root session `root-session-3b9d5743…` and read-back digest `a5756119…`.
The exact-image Authority and Target Agent are Ready with zero restarts. The corrected Genesis
cleanup successor crosses the former `recovery-intent-rejected` boundary and executes; its
protected Pod-log terminal token is `execution-failed/recovery-remint-ambiguous`. The coordinator
refuses that token as a worker receipt, the supported command exits 1 after 33:03.99, and postflight
finds the node Ready, 31 GiB free, and no credential worker Job or Pod.

Stable counterexample `AWS-ADMIN-CLEANUP-RECOVERY-REMINT-AMBIGUOUS-2026-08-29` proves the cleanup
permit family is now admitted and reaches the remint classifier. It does not prove that cleanup
completed, that the bounded IAM key family is absent, or that a fresh key may be minted. The narrow
next step is to trace the single closed construction producing `recovery-remint-ambiguous` before
deciding whether any behavior change is licensed.

Source tracing then proves the terminal cause has one construction site: execution must have
durably reached `cleanup-proven` with the remint flag set. The cleanup successor can reach that
state only by committing stable absence from its initial cleanup, restarting as
`intent-committed/remint-used`, consuming the one fresh create attempt, and committing stable
absence a second time after that attempt became ambiguous. The exact ambiguity trigger is
deliberately erased, but the safe continuation does not depend on it: the retained
`cleanup-proven/remint-used` phase is itself the positive cleanup proof. Widening the worker to a
second remint would defeat the bounded fence and is not licensed.

The protected Authority log timestamps the Generation-108 recovery at 22:56:23 EDT. Its 30-minute
active fence is certainly expired after 23:26:24 EDT. The next step is therefore no code change:
run the unchanged-source supported reconcile after that time, require exact recovery of the
retained cleanup-proven phase before a successor worker runs, and register the next terminal
observation.

### Generation-109 Repeated Cleanup-Remint Counterexample (2026-08-29)

After the active fence expires, Generation 109 rebuilds fully from cache, republishes the unchanged
local image `sha256:83c3fbf9…` and registry manifest `sha256:8a21c7f6…`, and takes the proven
exact-current containerd skip without archive/import. The root session and baseline read-back stay
unchanged. Before the successor worker runs, the protected Authority log records at 23:28:29 EDT
the exact predecessor observation `present/cleanup-proven/remint-used`, proving Generation 108's
positive cleanup continuation rather than inferred expiry.

The successor again emits `execution-failed/recovery-remint-ambiguous`; the coordinator refuses it
as a receipt, the supported command exits 1 after 1:37.98, and postflight finds the node Ready with
41 GiB free and no credential worker Job or Pod. Stable counterexample
`AWS-ADMIN-CLEANUP-RECOVERY-REMINT-AMBIGUOUS-REPEATED-2026-08-29` establishes that two independent
successors collapse a deterministic fresh-attempt cleanup trigger into one terminal label. The
narrow next diagnostic may distinguish only native IAM create dispatch ambiguity, native IAM 2xx
lost-result parsing, and the remaining closed authored cleanup triggers. It must carry no AWS
message, request ID, response body, key/target value, inventory count, or material, and may change
no cleanup, remint, retry, permit, or journal behavior.

### Recovery-Remint Cause Local Diagnostic Checkpoint (2026-08-29)

The generic native IAM boundary now preserves only whether an ambiguous create was not known to
dispatch or returned a successful response whose result could not be recovered. The AWS-admin
execution terminal lifts that distinction plus every other authored cleanup entrance into ten
exhaustive value-free causes: resumed cleanup-proven journal, nonempty intent inventory,
prepared-inventory divergence, create dispatch ambiguity, create lost result, created-key
predecessor collision, unavailable created material, invalid material, Target delivery failure,
and Target receipt mismatch. The classifier discards provider text, response bodies, request IDs,
inventory, key/material/target/receipt values, and delivery detail. It changes no cleanup, remint,
retry, permission, permit, journal, or delivery behavior and changes no durable wire.

Focused Sprint-2.116 remains **11/11**, the exact AWS-admin Authority group remains **39/39**, the
generic Credential Provisioner group passes **29/29**, all **4728/4728** primary cases and the
**27/33/31** auxiliary authority suites pass. Fourmolu is applied, HLint reports `No hints`,
documentation and diff checks pass, and the warning-clean all-target canonical `prodbox dev check`
exits 0 after 8:56.404. Gate-built binary
`sha256:b0cf31db99d2cdda3b79b2b33fca7eb4d2be2eadd39a72021d7d2c7a929764d6` is the
Generation-110 input and is byte-identical to `.build/prodbox`. Generation 109's protected
successor timestamp is 23:28:29 EDT; its 30-minute active fence is retained through 23:58:29 and
the supported Generation-110 reconcile starts only after 23:58:30.

### Generation-110 Target-Delivery Counterexample (2026-08-30)

Generation 110 starts at 23:58:35 EDT, builds local image
`sha256:6645b9e560786716638a6d3a63915441f1443ebe5004a866ccd9ad0479d5765a` in 1002.0 seconds,
publishes registry manifest
`sha256:985c3a58744ae49bf2d13f9c2dec8b537c271729e2bbabf63303959f3ef7626d`, and imports
containerd OCI manifest
`sha256:4a6937afd31aeddcd7cd4f77247a6ff32d8f8621c19672537408309eeea9550e` in 299.8 seconds.
Baseline reconciliation retains root session `root-session-3b9d5743…` and read-back digest
`a5756119…`. Authority and Target Agent are Ready on the exact local image with zero restarts, and
the protected Authority log again records
`journal-observation=present/cleanup-proven/remint-used` before the successor runs.

The successor Pod-log terminal is exactly
`execution-failed/recovery-remint-ambiguous/target-delivery-failed`. The coordinator refuses it as
a receipt, the supported command exits 1 after 33:22.148, and postflight finds the node Ready with
35 GiB free and no credential worker Job or Pod. Stable counterexample
`AWS-ADMIN-CLEANUP-RECOVERY-TARGET-DELIVERY-FAILED-2026-08-30` proves only that the fresh material's
delivery refused and the subsequent authoritative observation found no Target receipt before the
existing cleanup fold ran. It does not identify the delivery refusal or license retry,
authentication/capability, cleanup, remint, permit, or journal changes. Source tracing the exact
closed delivery boundary is next.

### Target-Delivery Cause Local Diagnostic Checkpoint (2026-08-30)

Source tracing proves `target-delivery-failed` begins at one direct-delivery boundary and that
Generation 110 reached neither Target-worker Job creation nor a Target receipt. The terminal now
preserves only a closed hierarchy: fourteen direct preflight causes plus retained custody; every
closed Target-intent transport, response-codec, HTTP class, authored refusal/unavailability class,
and decoder cause; or the exact one of twenty-three Target-worker coordinator constructors reached
after intent issuance. Explicit `other` arms erase unknown private intent detail, and each
payload-bearing coordinator error collapses to its constructor. HTTP status integers, response
bodies, Kubernetes errors, identities, payload/material/receipt values, and retained-custody detail
cannot enter the token. No delivery, authentication, retry, worker, cleanup, remint, permit,
journal, observation, or receipt behavior changes.

Focused Sprint-2.116 remains **11/11**, the exact AWS-admin Authority group remains **39/39**, the
generic Credential Provisioner group remains **29/29**, all **4728/4728** primary cases and the
**27/33/31** auxiliary authority suites pass, Fourmolu is applied, and HLint reports `No hints`.
Both documentation gates and `git diff --check` pass, and canonical `prodbox dev check` exits 0
after 8:55.66 with its warning-clean all-target build. Gate-built binary
`sha256:dae7176c20b73a4068ab4570ec6f744a8d6114b8f0bdfc7659d2053e3c42a438` is byte-identical to
`.build/prodbox` and is the Generation-111 diagnostic input. Generation 110's protected recovery
timestamp is 00:31:55 EDT, so its active fence is retained through 01:01:55 and no supported
successor starts before 01:01:56.

### Generation-111 Pre-Diagnostic Import Pressure (2026-08-30)

Generation 111 starts after the fence at 01:02:19 EDT and builds local image
`sha256:92001fa12f3cad9b1c6cca3c6c03a2fb186429984d3baff2ff56fadafee71548` in 993.3 seconds,
publishes registry manifest
`sha256:0f8017cc25b5b09e754aca08114239270747b0251c4ca0764c0327249342ae7c`, and completes the
required changed-source import in 315.6 seconds at OCI manifest
`sha256:f645107217a1d89af12354802e3631e45fd546cb9e69db225f1269328622e790`. The immediate
registry/MinIO round-trip then cannot connect and the supported command exits 1 after 32:25.81,
before Authority recovery or a credential worker runs.

Read-only postflight proves this is another crossing of the already registered
`LOCAL-RUNTIME-REIMPORT-DISK-PRESSURE-2026-08-29`, not a new delivery result: the node is Ready but
`DiskPressure=True` with the NoSchedule taint, eviction events name the ephemeral-storage floor,
registry and the retained control-plane Pods have been evicted or are Pending, and 28 GiB host
space remains. No new AWS-admin active-attempt fence was minted. The exact Generation-111 image is
now present in Docker, the registry, and RKE2 containerd.

Automatic recovery then stalls with 38 GiB host space free because kubelet's configured 10%
minimum reclaim is additional to its eviction threshold, while the bytes it cannot reclaim belong
to Docker rather than RKE2 containerd. Read-only inventory finds **15** dangling images from the
exact managed runtime repository, each with about 2.88 GB unique data; `docker system df` reports
55.97 GB of images and 51.19 GB reclaimable. Source has no retention step: each changed build moves
the previous runtime image to a dangling state, and kubelet cannot garbage-collect Docker's
separate store. Register stable counterexample
`LOCAL-RUNTIME-DANGLING-IMAGE-RETENTION-2026-08-30`. It licenses only a prodbox-owned exact-repository
retention fold that selects canonical dangling image IDs from Docker's machine-formatted inventory,
deletes no tagged or foreign image, and refuses malformed observation or any failed deletion. The
fold must run before build and after the publication/import attempt so a changed generation has
headroom and cannot leave its predecessor accumulating. Broad Docker prune, build-cache deletion,
Kubernetes mutation, or weakening the kubelet floor is not licensed.

### Managed Runtime-Image Retention Local Checkpoint (2026-08-30)

The native install plan now places exact managed-runtime retention after host resource/inotify
guardrails and before RKE2 readiness, so it can recover a pressure-tainted node before registry
scheduling. The publication wrapper repeats the same reconcile before build and after every normal
publication/import result, with an exception cleanup arm. Its pure selector receives only
`docker image ls --filter dangling=true --no-trunc` machine rows, ignores foreign repositories,
accepts only canonical full `sha256:` IDs under the exact compiled runtime repository, rejects
malformed/duplicate/noncanonical observations, deletes each selected ID without `--force`, and
requires an independently observed empty managed-dangling read-back. Tagged images, broad prune,
build-cache deletion, and arbitrary IDs cannot be rendered.

Focused Sprint-2.116 passes **12/12**, the exact AWS-admin Authority group remains **39/39**, the
generic Credential Provisioner group remains **29/29**, native plan renderers pass **30/30**, all
**4729/4729** primary cases and the **27/33/31** auxiliary authority suites pass. Fourmolu is
applied, HLint reports `No hints`, both documentation gates and `git diff --check` pass. The
canonical `prodbox dev check` exits 0 after 8:59.22 with its warning-clean all-target build.
Gate-built binary `sha256:5718b68d87a11218ec6de1e64da5b1bfd4d64d5f1e90168d67a5145f0cd3fcc7`
is byte-identical to `.build/prodbox` and is the supported retention/deployment input.

### Generation-112 Exact Retention Crossing and Compile-Layer Finding (2026-08-30)

Generation 112 starts at 02:16:24 EDT. The supported early host preflight observes the exact
machine inventory, deletes all **15** dangling images under the compiled managed-runtime
repository individually without force, and requires an empty read-back. No tagged or foreign image
is selected. Read-only postflight proves the node has recovered to `DiskPressure=False` without a
taint, the registry is Running/Ready, and the managed dangling inventory remains empty. This is the
required live proof for `LOCAL-RUNTIME-DANGLING-IMAGE-RETENTION-2026-08-30`.

The command stops before image build because the admitted `minio` observation is 32,413,007
microseconds old when the `registry` edge requires at most 30,000,000 microseconds. It exits 1 after
1:17.18 and reaches neither Authority recovery nor an AWS-admin worker, so there is no new active
AWS-admin fence and no Target-delivery evidence. The single just-recovered-cluster observation
licenses only a supported retry, not an admission-bound or readiness change.

Postflight also proves that dangling-image deletion alone does not bound physical storage. Docker
image data falls to 12.75 GB, while 43.54 GB becomes reclaimable build cache. Read-only history of
the unchanged runtime image assigns **2.87 GB** to the single `cabal update`/`cabal build` layer,
matching the prior 2.88-GB per-generation unique measurement. An in-image read-only measurement
attributes 921 MB to `/opt/build/.build`, 1.2 GB to `/root/.cache/cabal`, and 539 MB to
`/root/.local/state/cabal`; the installed `/usr/local/bin/prodbox` is separate, and all Provider
programs are YAML. Register stable counterexample
`LOCAL-RUNTIME-COMPILE-LAYER-RETENTION-2026-08-30` before correction.

The licensed correction deletes exactly those build-only directories in the same Dockerfile `RUN`
after copying the installed executable, preventing their bytes from entering each generation
layer. It retains the single-stage Ubuntu image, in-image pinned GHC/Cabal toolchain, basic Docker
builder, checked-in source and YAML programs, and installed binary. It cannot render a global
Docker build-cache prune, tagged/foreign image deletion, buildx, or a BuildKit cache mount.

The correction is locally complete and its dedicated Sprint-2.116 regression binds the exact
same-`RUN` removal roots. Focused Sprint-2.116 passes **13/13**, all **4730/4730** primary cases and
the **27/33/31** auxiliary authority suites pass. Fourmolu is applied; HLint reports `No hints`;
both documentation gates and `git diff --check` pass. Canonical `prodbox dev check` exits 0 after
8:46.200 with its warning-clean all-target build. Because the production Haskell source is
unchanged, gate-built binary
`sha256:5718b68d87a11218ec6de1e64da5b1bfd4d64d5f1e90168d67a5145f0cd3fcc7` remains
byte-identical to `.build/prodbox` and is the supported deployment input. Live image-history,
storage, and Target-delivery proof remain.

### Generation-113 Compile-Layer Proof and Failed-Release Cleanup (2026-08-30)

Generation 113 starts at 02:42:09 EDT and crosses the prior stale admission unchanged. It builds
local image `sha256:34531fd44562fd9d541f11b826742cac78e0e27b6adce17cb65525f8347740fb` in
991.3 seconds, publishes registry manifest
`sha256:d5a181199e9d7c424714a045e5dd895ba4f97f7fe14347731bd28af891b6b18d`, and imports OCI
manifest `sha256:58d4d753d31fc5dc9962f9818b082f03ce0a4ff5dda55cf6209d50a9ea0d30f5` in
170.3 seconds. Post-publication retention deletes only the superseded Generation-111 local image
and requires the managed dangling set empty.

Independent read-only history closes
`LOCAL-RUNTIME-COMPILE-LAYER-RETENTION-2026-08-30`: the exact Cabal layer is **166 MB**, down from
2.87 GB, and total runtime-image size is **4,831,214,949 bytes**, down by about 2.71 GB. Docker
build-cache total changes only 50.99 → 51.19 GB while its reclaimable classification changes
43.54 → 46.44 GB; the removed compilation bytes do not enter the new final generation layer.
The node remains Ready with `DiskPressure=False`, no taint, and 29 GiB free.

The run then reaches the pre-existing failed Lifecycle Authority release rather than AWS-admin
recovery. The retained Pod still has Generation-110 rollout annotation `sha256:6645b9e5…`, old
Generation-111 registry identity `sha256:0f8017cc…`, and 18 CrashLoopBackOff restarts. Helm
readiness refuses; the supported failure branch prints those diagnostics, uninstalls the release,
and verifies absence. The command exits 1 after 25:32.173 before an exact-generation Authority,
Authority recovery, or an AWS-admin worker exists. No active AWS-admin fence is created. The
unchanged-source exact-current clean-release retry is licensed without a code change.

### Generation-114 Target-Intent Trust-Install Refusal (2026-08-30)

Generation 114 starts at 03:09:53 EDT. Its Docker build is entirely cached and reproduces local
image `sha256:34531fd44562fd9d541f11b826742cac78e0e27b6adce17cb65525f8347740fb` and registry
manifest `sha256:d5a181199e9d7c424714a045e5dd895ba4f97f7fe14347731bd28af891b6b18d`; the
exact-current containerd observation skips archive/import. The clean Lifecycle Authority and
current Target Agent are Ready with zero restarts, and each carries that exact image in both its
rollout annotation and runtime image ID. The retained root session and baseline read-back digest
remain unchanged.

Protected Authority recovery observes `present/cleanup-proven/remint-used` at 03:11:25.960 EDT.
The worker then emits the exact value-free terminal
`execution-failed/recovery-remint-ambiguous/target-delivery-failed/intent/unavailable/trust-install`.
The coordinator refuses it as a receipt and the supported command exits 1 after 1:50.997. No
AWS-admin Job or Pod remains. The managed dangling set is empty, the node is Ready with
`DiskPressure=False`, and host free space recovers to 39 GiB.

Register stable counterexample
`AWS-ADMIN-CLEANUP-RECOVERY-TARGET-INTENT-TRUST-INSTALL-UNAVAILABLE-2026-08-30`. The token proves
only that the authenticated Target-intent issue route could not install trust; it does not prove
the Target receipt, Target mutation, or provider state. Diagnose its exact closed boundary before
changing delivery, authentication, capability, retry, cleanup, remint, permit, or journal
behavior. The active-attempt fence remains intact through 03:41:25 EDT, and no supported successor
may start before 03:41:26.

### Target-Intent Trust-Install Cause Local Diagnostic Checkpoint (2026-08-30)

Source tracing proves Target-intent signing succeeded before the Authority called the authenticated
Target Agent trust-install route. The Target endpoint already distinguishes repository observation
unavailability from CAS unavailability, but the production client converted that response to
`show` text and the Authority endpoint then collapsed every trust-install failure to one generic
token. The diagnostic correction now classifies generic authenticated-client transport, codec,
and closed HTTP status causes plus every authored trust refusal, exact
`unavailable/observation`, exact `unavailable/cas`, and client read-back failure before private
detail crosses the Authority endpoint. Unknown refusal or unavailable detail becomes an explicit
`other` arm. The worker terminal preserves only the canonical value-free cause below
`intent/unavailable/trust-install`. Target trust installation, CAS/read-back, response class,
delivery, authentication, retry, cleanup, remint, permit, journal, and receipt behavior are
unchanged.

The new two-sided table proves every rendered cause is unique, exact observation and CAS
unavailability remain distinct, and different private unavailable/refusal payloads collapse to
their respective `other` tokens. Focused Sprint-2.116 passes **14/14**, all **4731/4731** primary
cases and the **27/33/31** auxiliary authority suites pass. Repository-pinned Fourmolu is applied,
HLint reports `No hints`, both documentation gates and `git diff --check` pass, and canonical
warning-clean `prodbox dev check` exits 0 after 542.05 seconds. Gate-built binary
`sha256:d1aa5c8717a259421a580059df6fe6783c9efb36791cd1944cbabc6157b06412` is byte-identical to
`.build/prodbox` and is the Generation-115 diagnostic input. No behavior change is licensed by
this checkpoint.

### Generation-115 Target Trust Observation Counterexample (2026-08-30)

Generation 115 starts at 03:41:35 EDT after the prior fence. It builds local image
`sha256:3e29094423e4ceed1f8f925966b244338d166569ad5f3787495810e4446d0aa6` in 1005.5
seconds, publishes registry manifest
`sha256:e1afb61b89d2cf3598719e7173ba3c3c85d82d0123ccdf992559430f12a5d10c`, and completes
the required changed-image import in 140.8 seconds at OCI manifest
`sha256:9d09895b374ef8eb0e3dd6de9c59c73b73ddcd42857a3d5000736d057052945a`.
Post-publication retention deletes only superseded local image `sha256:34531fd4…`. Baseline
reconciliation retains root session `root-session-3b9d5743…` and read-back digest `a5756119…`.

The clean exact-image Target Agent and Lifecycle Authority are Ready with zero restarts. Recovery
observes `present/cleanup-proven/remint-used` at 04:06:19.102 EDT. The protected worker terminal
then refines exactly to
`execution-failed/recovery-remint-ambiguous/target-delivery-failed/intent/unavailable/trust-install/unavailable/observation`.
The coordinator rejects it as a receipt and the supported command exits 1 after 1494.62 seconds.
Postflight finds no credential worker Job or Pod, the managed dangling inventory is empty, the node
is Ready with `DiskPressure=False` and no taint, and 42 GiB host space is free.

Register stable counterexample
`AWS-ADMIN-CLEANUP-RECOVERY-TARGET-TRUST-OBSERVATION-UNAVAILABLE-2026-08-30`. It proves the
authenticated Target Agent route could not authoritatively read its exact trust record before a CAS
decision; it is not a CAS refusal and does not prove absence, Target mutation, or delivery. Diagnose
the exact closed Vault observation boundary before changing policy, baseline currentness, session,
trust/CAS, retry, cleanup, remint, permit, journal, or receipt behavior. The new active-attempt fence
remains intact through 04:36:19 EDT; no supported successor may start before 04:36:20.

### Target Trust-Record Observation Local Diagnostic Checkpoint (2026-08-30)

The existing Vault session wrapper still performs the same cached acquisition and at most one
forbidden-triggered relogin around the same exact KV-v2 read. Its result now enters a closed
payload-free cause before rendering: acquisition versus relogin with sealed/forbidden/unavailable;
request 401, 403, other client/server/unexpected status, connection, timeout, or decode; and stored
record field absence, invalid base64, invalid record, target mismatch, or Agent-identity mismatch.
Exact request 404 remains the sole missing-record observation. Vault bodies, login detail, stored
bytes, Target identities, and decoded trust values cannot enter the Target response or worker
terminal. Unknown older response detail maps to `other`. Trust observation, CAS, read-back, retry,
policy, session, baseline, delivery, cleanup, remint, permit, journal, and receipt behavior do not
change.

The expanded two-sided Sprint-2.116 case passes **14/14** and proves unique exhaustive cause tokens,
payload erasure across distinct 403/login bodies, exact observation suffix parsing, and end-to-end
terminal nesting. All **4731/4731** primary cases and the **27/33/31** auxiliary authority suites
pass. Fourmolu is applied, HLint reports `No hints`, both documentation gates and
`git diff --check` pass, and canonical warning-clean `prodbox dev check` exits 0 after 535.95
seconds. Gate-built binary
`sha256:ffad42dae87c31e5e1ba5109bc54c17cc831ac81782fce40b7ab1864321c51c1` is byte-identical to
`.build/prodbox` and is the Generation-116 diagnostic input.

### Generation-116 Stale Target-Agent Rollout Trust Counterexample (2026-08-30)

Generation 116 starts at 04:36:36 EDT after the prior fence. It builds local image
`sha256:9531c714e1b8c5c2dd332ba288ff63b7f6f62c05764013f48ac91be3cc5856dc` in 986.1
seconds, publishes registry manifest
`sha256:20f9ea4001299bf397e1fa0947b679e22583a5e3b63831517d3142c84e533803`, and completes
the required changed-image import in 134.5 seconds at OCI manifest
`sha256:6be037a9c1fba82e80773edbaa7be98e417ace698c310b4878adee1b87d48ca9`.
Post-publication retention deletes only the superseded Generation-115 local image. Baseline
reconciliation retains root session `root-session-3b9d5743…` and read-back digest `a5756119…`.

Recovery observes `present/cleanup-proven/remint-used` at 05:00:49.674 EDT. The exact protected
worker terminal is
`execution-failed/recovery-remint-ambiguous/target-delivery-failed/intent/unavailable/trust-install/unavailable/observation/record/agent-identity-mismatch`.
This proves the exact trust object exists and decodes, names the requested target, but carries an
Agent identity different from the currently deployed exact Agent before any CAS decision. The
exact-image Target Agent and Lifecycle Authority are Ready with zero restarts. No credential Job
or Pod remains, managed dangling inventory is empty, the node is Ready with
`DiskPressure=False` and no taint, and 41 GiB host space is free.

Register stable counterexample
`AWS-ADMIN-CLEANUP-RECOVERY-TARGET-TRUST-AGENT-IDENTITY-MISMATCH-2026-08-30`. Source tracing binds
the stored record to the prior rollout digest while both the endpoint-local identity and desired
accepted-Authority record bind the new attested digest in the same cluster. Because observation
currently rejects the stored identity before `validateAdvance`, every ordinary Agent image rollout
becomes permanently unable to CAS-adopt its new exact identity. The counterexample licenses only a
same-cluster rollout transition under endpoint-local desired-identity equality and the existing
issuer identity/generation/key, Authority epoch, fence, CAS, and read-back checks. A different
cluster, any monotonic regression/conflict, an unobservable record, or an inexact desired local
identity must continue to refuse. The active-attempt fence remains intact through 05:30:49 EDT; no
supported successor may start before 05:30:50.

### Same-Cluster Target-Agent Rollout Trust Local Correction (2026-08-30)

The target-local repository now treats a decoded stored record as observable when its target is
exact and its Agent cluster equals the endpoint-local Agent cluster, even when its rollout digest
is the prior image. This supplies the existing monotonic installer with the versioned record; it
does not itself authorize a write. The desired CAS record must still name the endpoint's exact
current Agent identity. `validateAdvance` now refuses Agent identity change at the cluster boundary
while retaining issuer identity, issuer generation/key, Authority epoch, and fence monotonicity;
the existing version-bound CAS and exact read-back remain unchanged. A foreign-cluster record is
unobservable, a foreign-cluster advance refuses, and an inexact desired rollout cannot reach Vault
CAS.

The two-sided regression proves prior same-cluster observation and one exact CAS/read-back;
foreign-cluster observation and advance refusal; exact-local desired-record enforcement; and
same-cluster epoch regression without a CAS. Focused Sprint-2.116 passes **15/15**, the broader
Sprint-4.50 selection passes **595/595**, all **4732/4732** primary cases pass, and the auxiliary
authority suites pass **27/33/31**. Fourmolu is applied, HLint reports `No hints`, both
documentation gates and `git diff --check` pass, and canonical warning-clean `prodbox dev check`
exits 0. Gate-built and installed binary
`sha256:43322c9fd55677f0f87637f045356fa030cbe5c99f847ec7560987481882d1ca` is byte-identical
and is the Generation-117 qualification input. No supported successor may start before 05:30:50
EDT.

### Generation-117 Target-Worker Agent-Identity Counterexample (2026-08-30)

Generation 117 starts at 05:31:00 EDT after the prior fence. It builds local image
`sha256:22bae56e5f7271384eca6144b7e7c827930673700dbb8807ff6182973b573c6a` in 988.0
seconds, publishes registry manifest
`sha256:fe6d9ef60b8f61e9375d273556ac3c7e38044f71abd5ff880d4901a423a653b7`, and completes
the required changed-image import in 138.3 seconds at OCI manifest
`sha256:5309514eb8a9debd748b530771478ba99aa412ffb9858076093b37427605aaea`.
Post-publication retention deletes only the superseded Generation-116 local image. Baseline
reconciliation retains root session `root-session-3b9d5743…` and read-back digest `a5756119…`.

Recovery observes `present/cleanup-proven/remint-used` at 05:55:11.802 EDT. The worker terminal
crosses the Generation-116 trust observation and exact same-cluster trust installation, then ends
at
`execution-failed/recovery-remint-ambiguous/target-delivery-failed/worker/agent-identity-unavailable`.
This proves the trust correction reaches Target-worker coordination and moves the next refusal to
the coordinator's exact Agent-identity observation before any Target worker is created. The
exact-image Target Agent and Lifecycle Authority are Ready with zero restarts. No credential or
Target-worker Job/Pod remains, managed dangling inventory is empty, the node is Ready with
`DiskPressure=False` and no taint, and 41 GiB host space is free.

Register stable counterexample
`AWS-ADMIN-CLEANUP-RECOVERY-TARGET-WORKER-AGENT-IDENTITY-UNAVAILABLE-2026-08-30`. It licenses only
closed source/read-only diagnosis of the Target-worker coordinator's registered Agent identity
observation. It does not license weakening exact rollout evidence, substituting an Agent,
creating a worker without identity proof, changing trust, delivery, retry, cleanup, remint,
permit, journal, or receipt behavior. The active-attempt fence remains intact through 06:25:11
EDT; no supported successor may start before 06:25:12.

### Target-Agent Rollout Observation Diagnostic (2026-08-30)

Read-only source and cluster diagnosis closes the erased Generation-117 boundary without changing
its decision. The exact `target-secret-agent` Deployment is present at desired/observed generation
62, its API UID is valid, and both Deployment and Pod-template `prodbox.io/target-agent-identity`
and `prodbox.io/target-agent-rollout-digest` annotations agree with the current exact image. The
credential-provisioner and Lifecycle Authority ServiceAccounts both pass read-only authorization
for the exact cross-namespace Deployment GET. The one-shot credential Job, however, disables
ServiceAccount automount and projects only the `prodbox-control-plane`-audience Vault login token
at `/var/run/secrets/prodbox/token`; the `kubectl` subprocess has no Kubernetes client credential
at its standard in-cluster path.

The observation boundary now returns `TargetAgentRolloutObservationCause`, an exhaustive
payload-free ADT distinguishing subprocess acquisition, missing in-cluster Kubernetes client
configuration, authorization refusal, Deployment absence, other Kubernetes exit, and every exact
response/name/identity/digest/UID/generation validation stage. The nested worker token renders only
that closed cause; subprocess text, endpoint/user values, response bodies, annotations, identities,
and Kubernetes errors remain unrepresentable. No Kubernetes credential, RBAC, rollout-evidence,
worker-creation, trust, delivery, retry, cleanup, remint, permit, journal, or receipt behavior has
changed. Focused Sprint-2.116 remains **15/15**, the exact rollout-observation regression passes
**1/1**, broader Sprint-4.50 passes **595/595**, primary passes **4732/4732**, and the auxiliary
authority suites pass **27/33/31**. Fourmolu is applied, HLint reports `No hints`, both documentation
gates and `git diff --check` pass, and canonical warning-clean `prodbox dev check` exits 0. The
gate-built and installed binary is byte-identical at
`sha256:2538b528a5c90b1b507aa9eea8a60ad164890e27520dd0a53805a8191c0d829e` and is the
Generation-118 qualification input. Deploy the diagnostic and register the exact closed live
subclass before any behavior correction.

### Generation-118 Target-Worker Kubeconfig Counterexample (2026-08-30)

Generation 118 starts at 06:32:09 EDT after the prior fence. It builds local image
`sha256:107716dd85a0194b386ad492d9a8c94d562a8f995f0178f3482d6c9ca731f363` in 987.9
seconds, publishes registry manifest
`sha256:30ddcb04b216e31be6f6cdd2f498c606bf58ae2d087af92b8525eb501a819039`, and completes
the required changed-image import in 144.3 seconds at OCI manifest
`sha256:751c0eabd3c2b8a19b8adffeadf14b5fee3a3055eea491b10560f6e50eda9895`.
Post-publication retention deletes only the superseded Generation-117 local image. Baseline
reconciliation retains root session `root-session-3b9d5743…` and read-back digest `a5756119…`.

Recovery observes `present/cleanup-proven/remint-used` at 06:56:44.677 EDT. The exact terminal is
`execution-failed/recovery-remint-ambiguous/target-delivery-failed/worker/agent-identity-unavailable/kubeconfig-unavailable`.
This live-proves the diagnostic classification and the missing in-cluster Kubernetes client
credential before any Target worker is created. The exact-image Target Agent and Lifecycle
Authority Pods are Ready with zero restarts. No credential or Target-worker Job/Pod remains,
managed dangling image inventory is empty, the node is Ready with `DiskPressure=False` and no
taint, and 41 GiB host space is free. One pre-existing six-hour-old evicted non-current Target
Agent Deployment Pod remains failed; it is not selected as rollout evidence or a one-shot worker.

Register stable counterexample
`AWS-ADMIN-CLEANUP-RECOVERY-TARGET-WORKER-KUBECONFIG-UNAVAILABLE-2026-08-30`. It licenses only a
narrow, independently projected Kubernetes API client credential for the one-shot credential Job,
distinct from the existing `prodbox-control-plane`-audience Vault login token. Exact ServiceAccount,
audience, CA, namespace, read-only/mutation RBAC, rollout evidence, worker creation, trust,
delivery, retry, cleanup, remint, permit, journal, and receipt invariants remain unchanged. The
active-attempt fence remains intact through 07:26:44 EDT; no supported successor may start before
07:26:45.

### One-Shot Kubernetes API Identity Local Correction (2026-08-30)

The narrow correction preserves `automountServiceAccountToken: false` and the existing
`prodbox-control-plane`-audience Vault token at `/var/run/secrets/prodbox`. AWS-admin alone now
projects a separate Kubernetes-API-audience token, `kube-root-ca.crt`, and downward namespace at
the conventional in-cluster client directory. The external-EAB renderer remains without that
projection because its closed worker never calls Kubernetes. The retained substrate consumes the
existing typed `endpoints/kubernetes` observation and independently observes an exact post-DNAT
address/port egress rule in addition to public provider HTTPS; no Service-coordinate or literal
`6443` substitute is introduced. Existing exact ServiceAccount RBAC remains unchanged.

Focused Sprint-2.116 passes **17/17** and the external-material one-shot lifecycle passes
**14/14**. Both AWS-admin and external-EAB chart shapes render successfully; the AWS chart source
contains the conditional token/CA/namespace projection and compiled API-egress bindings, while
the native external manifest explicitly lacks the standard Kubernetes client path. The full
primary suite passes **4733/4733** and auxiliary suites pass **27/33/31**. Fourmolu is applied,
HLint reports `No hints`, documentation lint/check and diff hygiene pass, and canonical
warning-clean `prodbox dev check` exits 0. Its gate-built and installed binary is byte-identical at
`sha256:028ef5e112107e3631c30b2f210c9d3c974285e47e1c7e334548753aa000f3b1` and is the
Generation-119 input. The Generation-118 fence elapsed before qualification completed; live
deployment remains pending.

### Generation-119 Session-Revocation Counterexample (2026-08-30)

Generation 119 begins after the prior fence at 07:33 EDT. It builds local image
`sha256:c550d7c6aa79208c996a2c08f2f84aaed40abaf15888a5c1d2a6958246bec97f` in 987.1
seconds, publishes registry manifest
`sha256:9e51495fbdc4a033b0cdc2a09b5391124b1f4620761ee65f475e515f68a93a66`, and completes
the required changed-image import in 138.1 seconds at OCI manifest
`sha256:923436f66eb53a63510c445a5e841c6766cdb31d6d82b6e5f505edd82b0a54bf`. Retention
deletes only the superseded Generation-118 local image. Baseline reconciliation retains root
session `root-session-3b9d5743…` and read-back digest `a5756119…`.

Recovery observes `present/cleanup-proven/remint-used` at 07:59:03.579 EDT. Empty attach falls
back to the exact Pod log, whose sole closed terminal is
`worker-terminal-line=session-revocation-failed`; public behavior remains
`AuthorityBackupGenesisTargetFailed "AwsAdminCoordinatorReceiptRejected
AwsAdminWorkerReceiptDecodeFailed"`. This reaches the AWS-admin worker's closed
session-revocation boundary, but does not by itself prove whether the fenced action began. Stable
counterexample
`AWS-ADMIN-CLEANUP-RECOVERY-WORKER-SESSION-REVOCATION-FAILED-2026-08-30` licenses only
payload-free source/read-only diagnosis of that exact revocation stage before behavior changes.
It does not license accepting a receipt before revocation, weakening stable accessor absence,
changing target delivery, adding retry, or changing cleanup, remint, permit, journal, or receipt
invariants.

Read-only postflight proves Credential Provisioner NetworkPolicy generation 41 carries exact
observed post-DNAT API endpoint `192.168.2.46/32:6443` alongside the distinct provider-HTTPS
rule. Exact-image Target Agent and Lifecycle Authority Pods are Ready with zero restarts; no
credential or Target-worker Job/Pod remains, managed dangling inventory is empty, the node is
Ready with `DiskPressure=False` and no taint, and 41 GiB is free. The same pre-existing non-current
evicted Target Agent Deployment Pod remains failed and is not rollout or worker evidence. The
active one-remint fence runs through 08:29:03 EDT; no successor may begin before 08:29:04.

### AWS-Admin Session-Closure Diagnostic Local Checkpoint (2026-08-30)

Source tracing proves Generation 119 reached a boundary that already returned a closed typed
`ServiceSessionLifecycleError`, but the AWS-admin worker erased every non-action constructor into
one `session-revocation-failed` token. The shared lifecycle distinguishes retained-journal
availability/commit, binding mismatch/occupation/invalidity, pre-clean audit, cleaned login
ambiguity, cleanup audit/exception, and cleanup-journal commit. The worker's auditor acquisition
and cleanup refusals were also collapsed before that boundary. No live observation could therefore
select token acquisition, auditor login, accessor list/lookup, direct absence, stable-zero, or
journal closure without first repairing the diagnostic.

The locally qualified classifier carries only those finite closed constructors into the terminal
grammar below `session-revocation-failed`. Pre-clean and cleanup each distinguish identity,
observation, classification, visibility-wait, and stable-absence refusal; auditor login and
auditor-role cleanup remain separate. Provider/Vault text, token and accessor values, journal
identifiers, operation/attempt identifiers, and target/receipt values are unrepresentable. Direct
revoke response remains provisional, stable accessor absence still dominates the action result,
and no delivery, authentication, retry, cleanup, remint, permit, journal, completion, or receipt
behavior changes.

Focused Sprint-2.116 remains **17/17** and the full primary suite passes **4733/4733**. Auxiliary
authority suites pass **27/33/31**. The production library, executable, and complete primary unit
binary compile warning-clean; Fourmolu is applied, HLint reports `No hints`, and documentation and
diff gates pass. Canonical `prodbox dev check` exits 0, and its gate-built and installed
Generation-120 input is byte-identical at
`sha256:0f2b97eddf225f27db9ac01ddfdc601b509cc71e08f0412c181d4f01df4cbd9b`. The
Generation-119 fence remains active through 08:29:03 EDT; no supported successor is admitted
before 08:29:04.

### Generation-120 Session-Journal Counterexample (2026-08-30)

Generation 120 begins at 08:29:09 EDT after the prior fence. It builds local image
`sha256:4febc4ff2b941a922d9d231c39eee4b8496ba70ad8e82f2d27eef9ea96c50978` in 987.4
seconds, publishes registry manifest
`sha256:bd4cb86b478c4900d6055b27e2a9739bf7afb2427dfea3dc498b76b7e6b06e26`, and imports
OCI manifest `sha256:a0c2295879de0cbf4a275241eaf10b4114f64fedca69f0ed218dfe2c6c99de3e` in
146.7 seconds. Retention untags the Generation-119 registry identity and deletes only its local
image `sha256:c550d7c6aa79208c996a2c08f2f84aaed40abaf15888a5c1d2a6958246bec97f`.
Baseline reconciliation retains root session `root-session-3b9d5743…` and digest `a5756119…`.

Recovery observes `present/cleanup-proven/remint-used` at 08:54:13.791 EDT. Empty attach falls back
to the exact one-line Pod log, which now classifies as
`worker-terminal-line=session-revocation-failed/journal-unavailable`; the public
`AwsAdminCoordinatorReceiptDecodeFailed` refusal and exit 1 remain unchanged. Register stable
counterexample `AWS-ADMIN-CLEANUP-RECOVERY-WORKER-SESSION-JOURNAL-UNAVAILABLE-2026-08-30`.
It licenses only a payload-free stage diagnostic: the same constructor can arise during initial
binding allocation, before the fenced action begins, or during finalization after it returns. It
does not license changing the auditor's two-minute lease or any journal/session behavior before
that stage is live-proven.

Read-only postflight proves Credential Provisioner NetworkPolicy generation 42 retains exact API
egress `192.168.2.46/32:6443`; exact-image Target Agent and Lifecycle Authority are Ready with zero
restarts; no credential or Target-worker Job/Pod remains; managed dangling image inventory is
empty; the node is Ready without pressure or taint; and 44 GiB is free. The active fence runs
through 09:24:13 EDT; no successor may begin before 09:24:14.

### Session-Journal Stage Diagnostic Local Checkpoint (2026-08-30)

The narrow diagnostic now records a closed two-state action-progress latch beside the existing
original-error latch. Binding allocation failures retain their own value-free terminal. After
allocation, a journal-unavailable lifecycle result renders `acquisition/journal-unavailable` when
the worker action was never entered and `finalization/journal-unavailable` once the action entry
was observed. The latch changes no action, session, journal, cleanup, exception, cancellation, or
receipt outcome. It cannot carry time, token/accessor, Vault response, journal coordinate,
operation, target, or receipt values.

The two-sided Sprint-2.116 regression proves both exact projections, and the exhaustive terminal
grammar includes both tokens. Production library/executable/unit targets compile warning-clean;
Fourmolu is applied, HLint reports `No hints`, focused Sprint-2.116 passes **18/18**, full primary
passes **4734/4734**, auxiliary suites pass **27/33/31**, and documentation/diff gates pass.
Canonical `prodbox dev check` exits 0. Its gate-built and installed Generation-121 input is
byte-identical at
`sha256:084f01e867631b96152a3343fc36a2e9f2a81fb3d6ee4536695c1f4c2e4e97eb`; the
successor remains fenced until 09:24:14 EDT.

### Finalization Lease-Containment Correction (2026-08-30)

Read-only retained Kubernetes events complete the diagnosis without spending a diagnostic-only
successor. The Generation-120 credential container starts at 08:54:15 EDT, creates the exact
Target-worker Pod at 08:54:29, and is stopped at 08:57:02. The action therefore began positively,
and the terminal journal refusal belongs to finalization. The accessor-free auditor was minted
before the action with a fixed 120-second lease, while the Target worker alone has a bounded
180-second runtime. The observed 167-second credential-container lifetime crosses that auditor
expiry before finalization; the journal policy and initial acquisition had already admitted the
action.

The narrow correction gives the credential-provisioner auditor one compiled 300-second maximum,
consumed by both the Vault role TTL and worker login validation. It remains a non-renewable,
accessor-free batch token with unchanged policy. The 180-second Target-worker maximum is exported
only as a typed bound, and a regression proves it is strictly contained by the auditor lifetime;
the remaining 120 seconds cover surrounding journal/stable-absence finalization. External EAB,
worker service-token, completion-token, permissions, journal, action, cleanup, retry, permit,
delivery, and receipt behavior remain unchanged.

The same read-only event series registers a distinct next counterexample without folding its fix
into this correction:
`TARGET-WORKER-RUN-AS-NON-ROOT-IMAGE-METADATA-2026-08-30`. The created Target-worker Pod repeatedly
refuses admission because `runAsNonRoot` cannot prove the union image's root metadata non-root.
Generation 121 must first prove the auditor survives finalization and expose the existing
Target-worker terminal; only then may that separate runtime-identity defect be corrected.

The correction compiles warning-clean. Focused Sprint-2.116 passes **19/19**, full primary passes
**4735/4735**, auxiliary suites pass **27/33/31**, Fourmolu is applied, HLint reports `No hints`,
and documentation/diff gates pass. The previously recorded `sha256:084f01e8…` binary contains only
the stage diagnostic and is superseded as a deployment input; canonical validation and a new byte
identity remain before Generation 121. Canonical `prodbox dev check` subsequently exits 0; its
gate-built and installed correction binary is byte-identical at
`sha256:407a14ea70b3d17d9bb86db6357cb3ac2f91e99c894ed2827b4cbafc498fdc06`. The
fence is elapsed and Generation 121 is admitted.

### Generation-121 Finalization-Journal Counterexample Persists (2026-08-30)

Generation 121 begins after the prior fence and builds local image
`sha256:6fd0d5c472d04d60916e7162aa782a96d2d2fc5bc961a11010ae78f5c8fa7526` in 1006.4
seconds. It publishes registry manifest
`sha256:e47451408473a10e10ecd4232ee78b2ed8c1bb4b9687d385c2c6db89088e0cc5`, imports OCI
manifest `sha256:632b9653ed96f7a3a0e0173c6564b06da9ffe107dd94c085a5df143ad5049431` in
131.8 seconds, and deletes only Generation 120's superseded local image
`sha256:4febc4ff2b941a922d9d231c39eee4b8496ba70ad8e82f2d27eef9ea96c50978`.
Baseline reconciliation retains root session `root-session-3b9d5743…` and digest `a5756119…`.

Recovery again observes `present/cleanup-proven/remint-used`, now at 10:00:58.906 EDT. Empty attach
falls back to the exact one-line Pod log and renders
`worker-terminal-line=session-revocation-failed/finalization/journal-unavailable`; the public
`AwsAdminCoordinatorReceiptDecodeFailed` refusal and exit 1 remain unchanged. This is a repeated
instance of
`AWS-ADMIN-CLEANUP-RECOVERY-WORKER-SESSION-JOURNAL-UNAVAILABLE-2026-08-30`, not evidence that the
300-second source maximum corrected live finalization.

Timestamped Kubernetes and Vault events prove the credential worker starts at 10:01:00, creates
the Target-worker Job/Pod at 10:01:13, observes repeated `runAsNonRoot` image-metadata refusals from
10:01:14 through 10:03:43, and revokes the service-token lease at 10:03:48. The worker action was
entered and cleanup revoked its accessor-bearing session, but the accessor-free auditor could not
then read the retained journal. The next correction must first preserve the exact journal failure
class without provider values and repair that session-finalization boundary. The separately
registered `TARGET-WORKER-RUN-AS-NON-ROOT-IMAGE-METADATA-2026-08-30` correction remains ordered
after successful session finalization.

Read-only postflight proves Credential Provisioner NetworkPolicy generation 43 retains exact API
egress `192.168.2.46/32:6443`; no credential or Target-worker one-shot Job/Pod remains; the current
Target Agent and Lifecycle Authority use the exact Generation-121 image and are Ready; managed
dangling image inventory is empty; the node is Ready without pressure or taint; and 44 GiB is free.
The active fence runs through 10:30:58 EDT; no successor may begin before 10:30:59.

### Issued-Lease And Journal-Failure Diagnostic Local Checkpoint (2026-08-30)

Generation 121 shows that an authored role maximum is not the same evidence as the lease Vault
actually issued. Worker admission now requires the accessor-free, non-renewable batch auditor's
issued lease to equal the one compiled 300-second role bound; an otherwise valid shorter lease
refuses before action entry as `auditor-lease-insufficient`. This changes no exact-lease success
path and cannot admit a token the prior maximum-only check refused.

The retained journal's bounded internal failure detail is projected into a closed cause before it
can reach the worker terminal: authentication rejected, authorization rejected, not found,
timeout, transport failed, decode failed, invalid journal, or other. Acquisition and finalization
each render that cause below their existing stage. Fixed HTTP status prefixes and the known
invalid-token marker are used only for classification; response bodies, status integers, URLs,
journal coordinates, tokens/accessors, and private detail remain unrenderable. A regression feeds
distinct private strings through both action stages and proves only the closed tokens survive.

Production and all affected tests compile warning-clean. Focused Sprint-2.116 passes **20/20**,
the exact AWS-admin Authority group passes **42/42**, full primary passes **4736/4736**, and
auxiliary authority suites pass **27/33/31**. Fourmolu is applied; HLint, documentation, diff,
and canonical gates pass. `prodbox dev check` exits 0; its gate-built and installed executable is
byte-identical at
`sha256:1ab85cd4466469be734ca023189e319c2f6a3b51789c0bdabd2977e2aee313fa`.
The Generation-121 fence elapsed at 10:30:59 EDT, so Generation 122 is admitted.

### Generation-122 Issued-Lease Counterexample (2026-08-30)

Generation 122 begins after local qualification and the elapsed fence. It builds local image
`sha256:32508d57090290ca0160d7dd186c84a21f9d947185dbb96193a08ba46e049cc0` in 1003.2
seconds, publishes registry manifest
`sha256:6aa2ce1404c14eb4690a2ccea442b268e9812829c34f2ac5c2bc576785ec0a84`, imports OCI
manifest `sha256:9c4328df56042789ff03840db34895fd67cef37718abf7c295a5eb70e5debc9e` in
121.5 seconds, and deletes only Generation 121's superseded local image
`sha256:6fd0d5c472d04d60916e7162aa782a96d2d2fc5bc961a11010ae78f5c8fa7526`.

Baseline reconciliation again returns root session `root-session-3b9d5743…` and digest
`a5756119…`. Recovery observes `present/cleanup-proven/remint-used` at 10:58:13.372 EDT, then the
new exact issued-lease check refuses before action entry as
`worker-terminal-line=session-revocation-failed/auditor-lease-insufficient`. Public receipt decode
remains fail-closed and the command exits 1. No Target-worker Job is created. Register stable
counterexample `VAULT-BASELINE-TARGET-REVISION-OMITTED-2026-08-30`: the 300-second role change did
not append a compiled baseline target, so the retained completed root/provisioner session still
qualifies its older target set as current and replays the prior read-back rather than opening a new
root session to apply the changed role.

The correction is to append one exact baseline target for credential-provisioner auditor lease
containment. The existing current-target comparison will then make the older completed receipt
non-current, mint a fresh root-session identity, run the allowlisted baseline/provisioner repair,
and read back the complete new target set. Do not special-case or delete the retained journal, and
do not weaken exact issued-lease admission. The Target-worker runtime-identity correction remains
ordered after the new baseline is live-proven.

Read-only postflight proves Credential Provisioner NetworkPolicy generation 44 retains exact
`192.168.2.46/32:6443` API egress; no credential one-shot Job/Pod remains and no Target-worker was
created; current Target Agent and Lifecycle Authority are exact-image Ready; managed dangling
inventory is empty; the node is Ready without pressure or taint; and 43 GiB is free. The active
fence runs through 11:28:13 EDT; no successor may begin before 11:28:14.

### Auditor-Lease Baseline-Revision Local Checkpoint (2026-08-30)

The root baseline now appends
`BaselineCredentialProvisionerAuditorLeaseContainment` after every previously deployed target.
That append preserves the established wire order and makes Generation 122's exact 19-target
receipt admissible only as a closed restart input: it is never current, and no in-progress state
may carry it. The native planner therefore chooses a fresh root-session identity, begins at
incomplete-generate-root cancellation, reapplies the complete baseline, and requires exact
20-target read-back. The retained receipt is neither deleted nor special-cased into current state.

A test-local copy of the Generation-122 wire schema proves canonical decode, non-current planning,
fresh-session restart, and rejection of a partial older set. The preceding 18-target
completion-principal schema remains independently pinned. Production and affected tests compile
warning-clean; focused Sprint-2.116 passes **21/21**, full primary passes **4737/4737**, auxiliary
authority suites pass **27/33/31**, Fourmolu is applied, HLint reports `No hints`, and diff hygiene
passes. Documentation and repository-policy gates pass, and canonical `prodbox dev check` exits 0.
Its gate-built and installed executable is byte-identical at
`sha256:9ddf4c88603ce24d942cdcc5e6856f8d40c5ce11aaa28083c2a9b8485f957355`. The
Generation-122 fence still controls live admission through 11:28:13 EDT; no Generation 123 command
may start before 11:28:14.

### Generation-123 Fresh Baseline And Target Runtime-Identity Counterexample (2026-08-30)

Generation 123 starts only after explicit admission at 11:28:21 EDT. It builds local image
`sha256:1788eda161fcb90916f393720b33f12c7c7129eef2a54053d6b85cdfa47603d5` in 990.3
seconds, publishes registry manifest
`sha256:9336a8f9d2a143c71fc182c44a1d7dd051602749e8643570262f374fd6aa58d3`, imports OCI
manifest `sha256:ae2689ff1451d8d2414b452ed732069625a916a541508f9bca9e6d01aacc0da4` in
149.3 seconds, and deletes only Generation 122's superseded local image
`sha256:32508d57090290ca0160d7dd186c84a21f9d947185dbb96193a08ba46e049cc0`.

The appended target forces fresh root session `root-session-9c54db6a…`, distinct from retained
`root-session-3b9d5743…`, and exact baseline read-back completes at digest `a5756119…`. The issued
auditor therefore crosses exact lease admission and session finalization; the worker terminal is
now exactly
`execution-failed/recovery-remint-ambiguous/target-delivery-failed/worker/observation-failed`, not
`session-revocation-failed`. This live-proves the baseline correction and admits the already
registered `TARGET-WORKER-RUN-AS-NON-ROOT-IMAGE-METADATA-2026-08-30` correction.

Read-only events pin Target Job creation at 11:53:39 EDT and the repeated kubelet refusal through
11:55:59 EDT: the container has `runAsNonRoot` but the union image declares root. Cleanup removes
both credential and Target one-shot Jobs/Pods. NetworkPolicy generation 45 retains exact
`192.168.2.46/32:6443`; the current Target Agent and Lifecycle Authority are exact-image Ready;
the node is Ready without pressure or taint; and 43 GiB is free. Use the conservative terminal-
observation fence through 12:26:26 EDT; no Generation 124 command may start before 12:26:27.

The next correction must give the Target worker Pod an explicit numeric non-root UID, GID, and
filesystem group while retaining `runAsNonRoot`, `RuntimeDefault`, privilege-escalation denial,
read-only root filesystem, dropped capabilities, exact projected identities, and existing cleanup.

### Target-Worker Explicit Runtime Identity Local Checkpoint (2026-08-30)

The Target-worker renderer now owns numeric UID, GID, and filesystem group `65532` at the Pod
boundary and uses `OnRootMismatch` group ownership. The union image remains role-neutral with root
metadata; Pod admission no longer infers identity from it. Existing `runAsNonRoot`, RuntimeDefault
seccomp, no privilege escalation, read-only root filesystem, dropped capabilities, Guaranteed-QoS
resources, tmpfs, projected Vault/Kubernetes identities, ServiceAccount automount denial, immutable
image binding, attestation, and exact cleanup are unchanged.

A structural regression extracts and compares the complete Pod security-context object rather
than relying on incidental encoded text. Production and affected tests compile warning-clean; the
complete Target materializer group passes **34/34**, focused Sprint-2.116 passes **22/22**, full
primary passes **4737/4737**, and auxiliary authority suites pass **27/33/31**. Fourmolu is
applied, HLint reports `No hints`, and documentation, repository-policy, diff, and canonical gates
pass. `prodbox dev check` exits 0; its gate-built and installed executable is byte-identical at
`sha256:7bd270969e0db19afc180c4dae839c56d38c4a442b79b9a721f09ff5891bcd57`. The
conservative fence still forbids a successor before 12:26:27 EDT.

### Generation-124 Started-Worker Observation Counterexample (2026-08-30)

Generation 124 starts after explicit 12:26:38 EDT admission. It builds local image
`sha256:17e9bde44358c66b56018d1bfbfa80a4d930c5bd069b47e7486be5e83cfa8678` in 995.5
seconds, publishes registry manifest
`sha256:def7f3fa32367e17b5f02b95ea4785e1b1a2a4882886739e3561d9ee85e4add0`, imports OCI
manifest `sha256:d2a4d6d85e5c4abc8f52f7f577ed70dd3c2149a4e1f0b5a73f76e0393cf62cd9` in
153.6 seconds, and deletes only Generation 123's superseded local image
`sha256:1788eda161fcb90916f393720b33f12c7c7129eef2a54053d6b85cdfa47603d5`.
Baseline reconciliation correctly retains current root session `root-session-9c54db6a…` and digest
`a5756119…`.

The Target Job is created at 12:52:00 EDT, and the container is created and started at 12:52:01;
the former `runAsNonRoot`/root-metadata refusal is absent. The controller retains the Pod until
cleanup at 12:54:28, but the exact public terminal remains
`execution-failed/recovery-remint-ambiguous/target-delivery-failed/worker/observation-failed`.
Register stable counterexample
`TARGET-WORKER-POD-OBSERVATION-FAILED-AFTER-START-2026-08-30`: the explicit runtime-identity
correction is live-proven, and the next work is diagnostic-only classification of the bounded Pod
observation refusal before any observation, attestation, retry, or receipt behavior changes.

Postflight proves both one-shot Jobs/Pods absent, NetworkPolicy generation 46 with exact
`192.168.2.46/32:6443`, exact-image Ready Target Agent and Lifecycle Authority, a Ready node with
all pressure conditions false and no taints, and 43 GiB free. Use the conservative terminal-
observation fence through 13:24:54 EDT; no Generation 125 command may start before 13:24:55.

### Target-Worker Observation-Cause Diagnostic Local Checkpoint (2026-08-30)

The protected worker terminal now refines `observation-failed` with one closed value-free cause:
Pod Kubernetes exit, invalid Pod list, multiple Pods, Job-label mismatch, controlling-Job UID
invalid, container absent, declared image empty, container status absent, runtime-image identity
invalid, image-digest mismatch, annotation mismatch, ServiceAccount Kubernetes exit, invalid
ServiceAccount response, ServiceAccount name/namespace/UID mismatch, or `other`. Annotation names,
subprocess text, Kubernetes responses, UIDs, image identities, and every private detail are erased.

An exhaustive two-sided table maps every known internal refusal, proves all rendered tokens unique,
and feeds distinct private strings plus a private annotation name to prove only `other` or
`annotation-mismatch` survives. Observation attempts, delay/bounds, attestation, permit issuance,
attach, session cleanup, Job/Pod cleanup, and receipt behavior are unchanged. Production and
affected tests compile warning-clean; focused Sprint-2.116 passes **22/22**, exact AWS-admin
Authority passes **42/42**, and auxiliary authority suites pass **27/33/31**. Full primary and
passes **4737/4737**. Fourmolu, HLint, documentation, repository-policy, and diff gates pass; the
canonical aggregate gate also exits 0. Its gate-built and installed executable is byte-identical
at `sha256:d1329b57f293a64984d43fe3fc4c59ac4925cbada497d7ddb059a44e549ec162`.
The Generation-124 fence remains unchanged.

### Generation-125 Runtime-Identity-Shape Counterexample (2026-08-30)

Generation 125 starts after explicit 13:25:01 EDT admission. It builds local image
`sha256:105f2e58e416be51f74edaa92a797360026e88d424ed0c226a7e3007bda98806` in 987.1
seconds, publishes registry manifest
`sha256:7a3d018246c20525e625413ddfb9ceb2fa7a874fc7888cba0e22aa54d1250763`, imports OCI
manifest `sha256:2987e9484dfeae5c88c01fdf3575407590d081a7d5e24bef252aca37a8f0216c` in
142.2 seconds, and deletes only Generation 124's local image
`sha256:17e9bde44358c66b56018d1bfbfa80a4d930c5bd069b47e7486be5e83cfa8678`.
Baseline reconciliation retains exact root session `root-session-9c54db6a…` and digest
`a5756119…`.

The Target worker is created at 13:50:00 EDT and starts at 13:50:01. Its bounded observer then
retries until cleanup at 13:52:31, after which the credential worker is cleaned at 13:52:36. The
protected terminal is exact
`execution-failed/recovery-remint-ambiguous/target-delivery-failed/worker/observation-failed/runtime-image-identity-invalid`.
Register stable counterexample
`TARGET-WORKER-REPOSITORY-QUALIFIED-RUNTIME-IDENTITY-2026-08-30`: the Target observer's local
parser accepts only bare and scheme-prefixed digests, while Kubernetes can report the
repository-qualified runtime-manifest identity already accepted by the credential worker's
canonical parser. The correction reuses that canonical parser and removes the narrower duplicate;
it does not relax exact digest comparison or change attestation, permit, delivery, cleanup, or
receipt behavior.

Postflight proves no credential/Target one-shot residue, NetworkPolicy generation 47 with exact
`192.168.2.46/32:6443`, exact-image Ready Agent generation 70 and Authority generation 12, a
Ready pressure/taint-free node, and 43 GiB free. Use the conservative terminal-observation fence
through 14:22:57 EDT; no Generation 126 command may start before 14:22:58.

### Shared Runtime-Manifest Parser Correction Local Checkpoint (2026-08-30)

Target-worker Pod observation now uses the same canonical runtime-manifest identity parser as the
credential worker and deletes its narrower local parser. Its exact digest equality remains the
attestation predicate; only bare, scheme-prefixed, or repository-qualified encodings of that same
complete digest are accepted. Foreign and malformed identities still refuse. The warning-clean
all-target build passes, Target-materializer passes **34/34**, and focused Sprint-2.116 passes
**22/22**. Exact AWS-admin Authority passes **42/42**, full primary **4737/4737**, and auxiliary
suites **27/33/31**; Fourmolu, HLint, documentation, repository-policy, diff, and canonical gates
pass. `prodbox dev check` exits 0; its gate-built and installed executable is byte-identical at
`sha256:fd1760ea462b07ab6d9d64112d513cf6e8f81e8b99047bad9c1610d55c1618af`. The
Generation-125 fence remains unchanged.

### Validation

1. `prodbox dev check`
2. `prodbox test unit`
3. `prodbox dns check`
4. `prodbox test integration gateway-daemon`
5. `prodbox test integration gateway-pods`
6. Gateway image proof: the union runtime `docker/prodbox.Dockerfile` is single-stage `ubuntu:24.04`, installs
   `ghcup`, pins GHC `9.12.4`, and does not create symlinked Haskell tool shims
7. Registry proof: the gateway image is available from the in-cluster `registry:2` service for the
   native architecture of the supported host and cluster
8. Aggregate reruns: `prodbox test integration all` and `prodbox test all`

### Current Validation State

- `src/Prodbox/Dns.hs` owns the public `prodbox dns check` surface and preserves the
  inspection-only output contract against the repository Dhall settings plus Route 53.
- `src/Prodbox/Gateway.hs` owns the public `prodbox gateway start|status|config-gen` surfaces;
  `gateway start` runs through the native Haskell daemon runtime in
  `src/Prodbox/Gateway/Daemon.hs` using `runGatewayDaemon`.
- `src/Prodbox/Gateway/Types.hs` provides the daemon/config boundary, while `Bounds.hs`, `State.hs`,
  and `Orders.hs` own the validated bounded protocol values and semantic projection.
- The parsing layer retains certificate, key, CA, and socket metadata in the current config model;
  `src/Prodbox/Gateway/Peer.hs` and the daemon materialize bounded cursor/delta/repair transport over
  the configured peer-events port.
- `src/Prodbox/Gateway/Daemon.hs` provides the daemon runtime: heartbeat loop, gateway ownership
  loop, DNS write loop, HTTP REST server, and HMAC assertion signing. The state payload exposes
  bounded semantic/replay counts, a fixed recent-assertion hash ring, bounded nested peer cursors,
  `heartbeat_age_seconds`, and the DNS/continuity observability fields described by the gateway
  doctrine.
- `src/Prodbox/Gateway.hs` dials daemon state over `/v1/state`, so the public status path and daemon
  listener share one native transport. The historical use of that diagnostic route for in-cluster
  probes was removed by Sprint `3.25`.
- `src/Prodbox/Gateway/Daemon.hs` now drains the inbound REST request before closing the socket,
  keeping loopback-restricted NodePort-backed `prodbox gateway status` and the corresponding
  `gateway-daemon` validation path on one complete-response HTTP contract.
- `src/Prodbox/Gateway/Types.hs` now enforces the timeout range, interval minimums, and the
  documented relationships `heartbeat_interval_seconds <= timeout/2`,
  `reconnect_interval_seconds <= timeout`, and `sync_interval_seconds <= timeout*2`.
- `test/unit/Main.hs` proves parser routing plus renderer and template behavior for native
  `dns check`, `gateway start`, `gateway status`, and `gateway config-gen`, and
  `test/integration/CliSuite.hs` proves the built frontend for native `gateway status` and
  `gateway config-gen` plus native error handling for `gateway start`.
- The named validation commands in this sprint (`prodbox test integration gateway-daemon` and
  `prodbox test integration gateway-pods`) run executable native Haskell validation flows via
  `src/Prodbox/TestValidation.hs`.
- the union runtime `docker/prodbox.Dockerfile` is single-stage `ubuntu:24.04`, installs `ghcup`, pins GHC
  `9.12.4`, and no longer uses the mounted `haskell:9.6.7-slim` BuildKit context or symlinked
  GHC tool shims.
- the union runtime `docker/prodbox.Dockerfile` installs the official AWS CLI bundle from the native Debian host
  architecture detected at build time.
- `src/Prodbox/CLI/Rke2.hs` publishes the gateway image through native-host-architecture Docker
  build and anonymous push flows into the in-cluster `registry:2` service, with no mounted
  `haskell-toolchain` context.
- `src/Prodbox/Lib/ChartPlatform.hs` resolves the supported gateway chart image through that
  in-cluster registry.
- `charts/gateway/` keeps the pod contract repo-rootless, supplies typed `SecretRef.Vault`
  references resolved through Vault Kubernetes auth, and renders the Sprint `3.25` typed
  `/healthz` liveness plus `/readyz` readiness bindings.

### Remaining Work

None.

## Sprint 2.2: Formal Verification Entrypoint and DNS-Write-Gate Contract [✅ Done]

**Status**: Done
**Implementation**: `src/Prodbox/Tla.hs`, `documents/engineering/tla/`, `test/unit/Main.hs`, `src/Prodbox/TestPlan.hs`, `src/Prodbox/TestValidation.hs`
**Independent Validation**: `prodbox dev tla-check`, the native partition fixture, and local parser
tests exercise the formal entrypoint and model correspondence without a later phase or live AWS.
**Docs to update**: `documents/engineering/cli_command_surface.md`, `documents/engineering/distributed_gateway_architecture.md`, `documents/engineering/tla/README.md`, `documents/engineering/tla_modelling_assumptions.md`

### Objective

Retain the formal verification entrypoint and the explicit DNS-write-gate contract after the
gateway port.

### Deliverables

- `prodbox dev tla-check` remains part of the supported validation surface.
- Gateway config generation still emits `dns_write_gate` for the public-edge ownership surface that
  Sprint `2.3` later collapses to one canonical public record.
- The TLA+ model remains the authoritative formal surface for Route 53 write-ownership semantics.
- Gateway partition and ownership reasoning remain documented through the TLA+ spec and the
  modelling-assumptions correspondence notes.

### Validation

1. `prodbox dev tla-check`
2. `prodbox test integration gateway-partition`
3. `prodbox test integration gateway-pods`

### Current Validation State

- `src/Prodbox/Tla.hs` owns the public `prodbox dev tla-check` surface and preserves the Docker-backed
  TLC workflow plus `documents/engineering/tla/tlc_last_run.txt` result persistence.
- `test/unit/Main.hs` proves parser routing for native `tla-check`.
- Native Haskell `gateway config-gen` preserves `dns_write_gate` emission. All Python TLA+ and
  gateway wrappers have been removed. The current runtime-to-model boundary is documented in
  `documents/engineering/tla_modelling_assumptions.md`, including the current Haskell
  observability payload and the remaining intentional model/runtime compression points.
- `src/Prodbox/TestValidation.hs` now keeps `prodbox test integration gateway-partition` on a
  distinct native Haskell partition validation path with explicit report markers, while
  `src/Prodbox/Tla.hs` continues to own the separate formal `prodbox dev tla-check` surface.

### Remaining Work

None.

## Sprint 2.3: Single-Record Route 53 Ownership and Diagnostics [✅ Done]

**Status**: Done
**Implementation**: `src/Prodbox/Dns.hs`, `src/Prodbox/Gateway.hs`, `src/Prodbox/Gateway/Types.hs`, `src/Prodbox/TestPlan.hs`, `src/Prodbox/TestValidation.hs`, `documents/engineering/tla_modelling_assumptions.md`
**Independent Validation**: pure DNS classification and generated-config tests plus the local TLA+
and partition fixtures prove the one-record ownership contract; Route 53 observation is exercised
on the home/local substrate and is not a later-phase dependency.
**Docs to update**: `documents/engineering/cli_command_surface.md`, `documents/engineering/distributed_gateway_architecture.md`, `documents/engineering/tla/README.md`, `documents/engineering/tla_modelling_assumptions.md`

### Objective

Collapse the Route 53 ownership and diagnostics surface from explicit per-FQDN public hosts to the
single supported public record `test.resolvefintech.com`.

### Deliverables

- `dns_write_gate` emits and reasons about one canonical public hostname rather than a set of
  dedicated public hosts.
- `prodbox dns check` classifies one Route 53 record and fails fast when config or runtime state
  still implies multiple public-edge FQDNs.
- The gateway and TLA+ correspondence docs describe single-record write ownership and no longer
  present per-subdomain public DNS as the target doctrine.
- DNS validation explicitly proves that `test.resolvefintech.com` belongs to the selected hosted
  zone and that the supported public edge needs only one public DNS entry.

### Validation

1. `prodbox dev check`
2. `prodbox dns check`
3. `prodbox dev tla-check`
4. `prodbox test integration dns-aws`
5. `prodbox test integration gateway-partition`
6. `prodbox test integration public-dns`

### Current Validation State

- `src/Prodbox/Dns.hs` now inspects one canonical Route 53 record for
  `test.resolvefintech.com`, and the built-frontend plus native validation flows align on that
  one-record doctrine.
- Native Haskell `gateway config-gen` preserves `dns_write_gate` emission with one canonical
  public hostname, while `src/Prodbox/TestValidation.hs` keeps the corresponding gateway
  partition proof on the supported path.
- The gateway doctrine and TLA+ correspondence notes now describe single-record write ownership
  rather than per-subdomain public DNS.

### Remaining Work

None.

## Sprint 2.4: Peer Heartbeat Transport and Commit-Log Gossip [✅ Done]

**Status**: Done
**Implementation**: `src/Prodbox/Gateway/Daemon.hs`, `src/Prodbox/Gateway/Types.hs`, `src/Prodbox/Gateway/Peer.hs`, `charts/gateway/`, `test/unit/Main.hs`
**Independent Validation**: pure codec/signature/admission tests and the loopback daemon plus native
partition fixtures validate peer transport locally. Sprint `2.31` supersedes the original batch/log
shape without changing this sprint's independently proved listener/trust-material boundary.
**Docs to update**: `documents/engineering/distributed_gateway_architecture.md`, `documents/engineering/tla_modelling_assumptions.md`

### Objective

Materialize the then-documented peer-transport surface so each gateway daemon dials its mesh peers,
exchanges signed heartbeats, and replicates the append-only commit log. This is the historical
Sprint-`2.4` delivery record; Sprint `2.31` supersedes the log/transport representation. The landed runtime
maintains every node's view of every other node's last heartbeat from observed peer traffic
rather than from local self-update only, closing the documented gap between the in-cluster
runtime and the TLA+ model's peer-communication assumptions.

### Deliverables

- The daemon binds a transport listener on the configured peer-events port, consumes the
  certificate, key, CA, and socket fields retained in `DaemonConfig` and `Orders`, and validates
  inbound heartbeats against the configured per-node HMAC keys in `daemonEventKeys`.
- `stateLastHeartbeatTimes` is updated from inbound peer events rather than from the local
  heartbeat loop only.
- At Sprint `2.4` closure, the append-only commit log replicated between nodes with idempotent
  acceptance through `appendIfNew`; Sprint `2.31` replaces that now-unsupported representation
  with bounded semantic state and per-emitter/vector-cursor deltas.
- At Sprint `2.4` closure, `/v1/state` exposed per-peer transport health under `peer_transport`.
  Sprint `2.25` replaced that field with bounded `peer_inbound_health` and
  `peer_outbound_health`, and Sprint `2.31` added bounded nested receive cursors.
- `charts/gateway/` keeps the per-pod peer endpoint and trust material in place so the in-cluster
  steady state opens the documented peer mesh.
- `documents/engineering/tla_modelling_assumptions.md` records that peer transport is now
  materialized in the runtime, narrowing the "anti-entropy gossip not modelled in implementation"
  divergence to delivery-delay only.

### Validation

1. `prodbox dev check`
2. `prodbox test unit`
3. `prodbox test integration gateway-daemon`
4. `prodbox test integration gateway-pods`
5. `prodbox test integration gateway-partition`
6. `prodbox dev tla-check`

### Historical Validation State and Current Replacement

- At Sprint `2.4` closure, `src/Prodbox/Gateway/Peer.hs` implemented the original signed-event batch
  and pure acceptance/rejection boundary. Sprint `2.31` removes that batch and now uses bounded
  canonical-CBOR cursor/delta/repair frames carrying `SignedAssertion` values.
- `src/Prodbox/Gateway/Daemon.hs` retains the listener/dialer boundary, ingests bounded signed
  assertions through atomic STM updates, and renders the split bounded health/cursor diagnostics.
- The daemon now validates the retained certificate, key, and CA files before startup, resolves
  config-relative trust-material paths through `prodbox gateway start`, and binds the REST plus
  peer-events listeners on the configured local Orders hosts so the retained socket fields close
  on the authoritative runtime transport contract described by this sprint.
- Current unit coverage proves disposition computation, the runtime DNS predicate, bounded
  cursor/delta/repair round trips, and rejection paths for unknown emitters, signature mismatches,
  stale Orders, excessive timestamp skew, and oversized frames.

### Remaining Work

None.

## Sprint 2.5: Runtime Claim/Yield Emission and DNS-Write Gating [✅ Done]

**Status**: Done
**Implementation**: `src/Prodbox/Gateway/Daemon.hs`, `src/Prodbox/Gateway/Types.hs`, `test/unit/Main.hs`
**Independent Validation**: pure ownership/DNS-authority tables, bounded state-fold tests, the
native partition fixture, and the finite TLA+ model prove claim-before-write and yield-before-
reclaim without a later phase or live Route 53 mutation.
**Docs to update**: `documents/engineering/distributed_gateway_architecture.md`, `documents/engineering/tla_modelling_assumptions.md`

### Objective

Lift the TLA+-modelled claim/yield protocol and the `CanWriteDns` predicate into the executable
daemon so DNS-write authority depends on a recorded ownership transition, not only on the in-
memory election projection. Closing this sprint eliminates the brief dual-writer window during
partition heal that today is benign only because Route 53 UPSERT happens to be idempotent.

### Deliverables

- `gatewayLoop` emits a signed bounded `OwnershipClaim` assertion on the non-owner-to-owner
  transition and a signed bounded `OwnershipYield` assertion on the owner-to-non-owner transition;
  Sprint `2.31` removes the historical commit-log carrier.
- `dnsWriteLoop` writes the Route 53 record only when the local node is owner AND the most
  recent applicable claim event is the local node's claim AND no later yield from the local node
  is present, via the runtime `canWriteDns` predicate.
- `ClaimPrecedesWrite` and `YieldPrecedesReclaim` from the TLA+ spec hold on the bounded semantic
  ownership projection, not only on the model.
- `/v1/state` exposes the current `node_disposition` and `peer_dispositions` plus `can_write_dns`.
- A stale owner cannot reclaim DNS write authority without first observing its own yield being
  superseded by a fresh claim.

### Validation

1. `prodbox dev check`
2. `prodbox test unit`
3. `prodbox test integration gateway-daemon`
4. `prodbox test integration gateway-partition`
5. `prodbox dev tla-check`

### Current Validation State

- `nodeDisposition` and `canWriteDns` in `src/Prodbox/Gateway/Types.hs` compute the runtime
  predicate without IO and are exercised in unit tests.
- `gatewayLoop` records `statePreviousOwner` so transition detection is precise across cycles and
  publishes continuity-staged ownership assertions through the configured event key.
- `/v1/state` now renders `can_write_dns`, `node_disposition`, and `peer_dispositions`
  alongside bounded semantic/replay/cursor and continuity diagnostics; it exposes no process-
  lifetime event total.

### Remaining Work

None.

## Sprint 2.6: Operator Time-Base Discipline [✅ Done]

**Status**: Done
**Implementation**: `src/Prodbox/Host.hs`, `src/Prodbox/Gateway/Daemon.hs`, `src/Prodbox/Gateway/Types.hs`, `src/Prodbox/Gateway/Peer.hs`, `test/unit/Main.hs`
**Independent Validation**: pure `timedatectl` disposition and signed-assertion skew tables plus
the local daemon fixture validate the time-base gate without a later phase; operator host
observation is a direct Phase-2 check.
**Docs to update**: `documents/engineering/distributed_gateway_architecture.md`, `documents/engineering/tla_modelling_assumptions.md`

### Objective

Make the daemon's reliance on bounded clock skew explicit and operator-verifiable, since every
freshness judgment in `gatewayLoop` and every claim/yield ordering check compares wall-clock UTC
stamps across nodes. The TLA+ model's bounded-delay assumption maps to a runtime-enforced skew
limit rather than to an implicit operator assumption.

### Deliverables

- `prodbox host info` reports the host's NTP synchronization disposition derived from
  `timedatectl status` and fails fast when the system clock is unsynchronized.
- The gateway daemon refuses inbound peer events whose timestamps exceed
  `daemonMaxClockSkewSeconds` (default 10 seconds, range `[0.1, 600]`) and records the maximum
  observed skew on `/v1/state` as `max_clock_skew_seconds_observed`.
- `documents/engineering/distributed_gateway_architecture.md` names the supported skew bound, the
  consequences of breaching it, and the operator response.
- `documents/engineering/tla_modelling_assumptions.md` records that the model's bounded-delay
  assumption is now mapped to a runtime-enforced skew bound.

### Validation

1. `prodbox dev check`
2. `prodbox test unit`
3. `prodbox test integration gateway-daemon`
4. `prodbox host info` reports the supported NTP synchronization state in its supported-host
   disposition

### Current Validation State

- `parseTimedatectlNtpDisposition` and `renderHostInfoReport` in `src/Prodbox/Host.hs` are unit-
  tested for synchronized, unsynchronized, and unknown dispositions.
- `handlePeerRequest` rejects events whose timestamp lies outside the configured skew bound and
  the reject reason is surfaced through the peer push response.

### Remaining Work

None.

## Sprint 2.7: Orders-Promotion Coordination [✅ Done]

**Status**: Done
**Implementation**: `src/Prodbox/Gateway/Daemon.hs`, `src/Prodbox/Gateway/Types.hs`, `src/Prodbox/Gateway/Peer.hs`, `test/unit/Main.hs`
**Independent Validation**: pure Orders-version admission/state tests, the native partition fixture,
and the finite TLA+ model validate the stale-node refusal and restart-based promotion contract
without any later phase.
**Docs to update**: `documents/engineering/distributed_gateway_architecture.md`, `documents/engineering/tla_modelling_assumptions.md`

### Objective

Coordinate Orders promotion across the gateway mesh so a change to `ranked_nodes` or
`heartbeat_timeout_seconds` is adopted atomically by every live daemon rather than per-node on
local restart. This closes the documented gap where a mid-flight Orders change on one node can
disagree with a peer's view of `RankOrder`.

### Deliverables

- Orders documents carry the existing monotonic `version_utc` field, peer push messages include
  the sender's `orders_version_utc`, and the receiver returns `409 Conflict` when the sender's
  view is older than the local view.
- The daemon tracks the highest observed Orders version on `/v1/state`; bounded cursor/delta/repair
  requests carry the sender Orders version and reject stale senders before semantic application.
- A daemon rebooting against a stale Orders version refuses to claim ownership in `gatewayLoop`
  while `stateLatestObservedOrdersVersion > stateOrdersVersionUtc`.
- `documents/engineering/tla_modelling_assumptions.md` records the Orders-version invariant and
  the supported promotion procedure.

### Validation

1. `prodbox dev check`
2. `prodbox test unit`
3. `prodbox test integration gateway-daemon`
4. `prodbox test integration gateway-partition`
5. `prodbox dev tla-check`

### Current Validation State

- Bounded peer cursor/delta/repair requests carry `sender_orders_version_utc` end to end in
  `src/Prodbox/Gateway/Peer.hs`; stale sender Orders and a locally observed newer Orders version are
  rejected before semantic application.
- `gatewayLoop` blocks ownership claims while the latest observed Orders version is newer than
  the local one, and `/v1/state` reports both `orders_version_utc` and
  `latest_observed_orders_version_utc`.

### Remaining Work

None.

## Sprint 2.8: Remove Legacy `timedatectl` NTP Field Fallback [✅ Done]

**Status**: Done
**Implementation**: `src/Prodbox/Host.hs`, `test/unit/Main.hs`, `DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md`
**Independent Validation**: pure parser tables and repository text search prove the unsupported
fallback is absent; `prodbox host info` exercises the supported field directly with no later phase.
**Docs to update**: `DEVELOPMENT_PLAN/README.md`, `DEVELOPMENT_PLAN/00-overview.md`, `DEVELOPMENT_PLAN/phase-2-gateway-dns.md`, `DEVELOPMENT_PLAN/phase-6-clean-room-handoff.md`, `DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md`

### Objective

Remove the retained compatibility branch for older `timedatectl status` output from the supported
host-info path so the time-base-discipline surface closes only on the Ubuntu 24.04 field format
described by the current doctrine.

### Deliverables

- `parseTimedatectlNtpDisposition` recognizes only the supported
  `System clock synchronized: yes/no` field on the supported host gate.
- The legacy cleanup ledger entry for the `NTP synchronized` fallback is moved to `Completed`
  once the compatibility branch is deleted.
- Unit coverage keeps the supported host-info parsing contract explicit after the fallback branch
  is removed.

### Validation

1. `prodbox dev check`
2. `prodbox test unit`
3. `prodbox host info` reports the supported NTP synchronization state on hosts whose
   `timedatectl status` exposes `System clock synchronized`
4. Repository text-search proof shows `src/Prodbox/Host.hs` no longer accepts the legacy
   `NTP synchronized` field on the supported path

### Current Validation State

- `parseTimedatectlNtpDisposition` now recognizes only `System clock synchronized: yes/no` and
  returns `NtpUnknown` when only the legacy `NTP synchronized` field is present.
- `test/unit/Main.hs` keeps the supported-field and legacy-field parsing outcomes explicit in the
  host NTP disposition suite.
- [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md) records the fallback removal in
  `Completed`; at this sprint's closure the pending-removal ledger returned to zero.

### Remaining Work

None.

## Sprint 2.9: Explicit Daemon Lifecycle [✅ Done]

**Status**: Done (with May 24, 2026 revision note for the pure-Dhall config doctrine
adoption — Sprint 0.8). Under
[config_doctrine.md §8](../documents/engineering/config_doctrine.md#8-boot-vs-live-split-and-the-restart-contract),
the existing drain machinery (`liveDrainDeadlineSeconds` default 30s, `bracketOnError`)
is reused verbatim for the new boot-field-change exit path: file-watch detects a
BootConfig diff, daemon drains, exits with `ExitSuccess`, and the kubelet restarts the
Pod. No Sprint 2.9 deliverable regresses; the drain bracket gains a new caller in
Sprint 2.21.
**Implementation**: `src/Prodbox/Gateway/Daemon.hs`, `src/Prodbox/Gateway.hs`
**Independent Validation**: the daemon-lifecycle process fixture and pure lifecycle/worker tests
exercise acquire, serve, bounded drain, force-drain, and failure classification locally with fake
prerequisites and no later-phase dependency.
**Docs to update**: `documents/engineering/distributed_gateway_architecture.md`,
`documents/engineering/effect_interpreter.md`

### Objective

Adopt [distributed_gateway_architecture.md#daemon-lifecycle](../documents/engineering/distributed_gateway_architecture.md#daemon-lifecycle).

### Deliverables

- Refactor `Prodbox.Gateway.Daemon` so the seven-step
  `load→prereq→acquire→ready→serve→drain→exit` lifecycle is visible in the top-level
  `bracket` / `withAsync` tree.
- The prerequisite registry (Sprint 1.9) gates `acquire`.
- SIGTERM/SIGINT install a shared `TMVar`; drain is bounded by the configured deadline.
- `Control.Concurrent.Async` only; `forkIO` is forbidden in daemon code paths (hlint custom
  rule enforced via Sprint 1.10 lint stack, with the negative-space symbol rules introduced
  in Sprint 1.19).
- Worker loops (peer listener, peer dialer, gateway ownership loop, DNS write loop) are
  wrapped in `try`/`catch` plus bounded retry-with-backoff using the `RetryPolicy` values
  from Sprint 1.13; no naked `forever` survives on the supported path per
  [distributed_gateway_architecture.md#daemon-lifecycle](../documents/engineering/distributed_gateway_architecture.md#daemon-lifecycle).
- The graceful-drain deadline defaults to **30 seconds** per
  [distributed_gateway_architecture.md#daemon-lifecycle](../documents/engineering/distributed_gateway_architecture.md#daemon-lifecycle)and is sourced from `LiveConfig`
  (Sprint 2.11) so operators tune it without a restart.
- Resources with external side effects (DB connections, file locks, message-broker
  consumer registrations) use `bracketOnError` per
  [distributed_gateway_architecture.md#daemon-lifecycle](../documents/engineering/distributed_gateway_architecture.md#daemon-lifecycle)so cleanup runs on every exit path,
  including exceptions raised mid-acquire. Plain `bracket` continues to govern resources
  without external side effects.
- Sprint 0.4 round-3 extension: enumerate the structured-concurrency primitive set
  as the closed set worker loops may use:
  `Control.Concurrent.Async.withAsync`, `race`, `concurrently`, and
  `replicateConcurrently`, per
  [distributed_gateway_architecture.md#daemon-lifecycle](../documents/engineering/distributed_gateway_architecture.md#daemon-lifecycle). The
  `.hlint.yaml` negative-space rules from Sprint 1.19 (which already refuse
  `forkIO`) extend with a positive-space rule requiring every `Async` primitive
  used in daemon paths to come from this set; introducing `async`/`wait` without
  a surrounding `withAsync`, or `mapConcurrently_` in place of
  `replicateConcurrently`, fails `prodbox dev lint haskell` with the doctrine-named
  rule.

### Validation

1. The `prodbox-daemon-lifecycle` stanza (Sprint 2.14) exercises a full lifecycle.
2. Lint refuses `forkIO` under `src/Prodbox/Gateway/`.
3. Injecting a synthetic recoverable error into a worker loop confirms the
   `try`/`catch` plus backoff wrapper restarts the loop within the retry policy and that
   sustained failures classify the error as `Fatal` (Sprint 1.14) and propagate.
4. The lifecycle stanza asserts the drain deadline defaults to 30 seconds when the
   `LiveConfig` value is unset and tracks a `LiveConfig` override when one is provided.
5. A unit test confirms that an exception raised inside the `bracketOnError`-guarded
   acquire of a representative external-side-effect resource runs the release path.

### Current Validation State

- Current local validation for the active daemon-lifecycle slice has passed
  `cabal test --builddir=.build prodbox-daemon-lifecycle --test-options=--hide-successes`,
  `cabal test --builddir=.build prodbox-unit --test-options=--hide-successes`,
  `cabal test --builddir=.build prodbox-haskell-style --test-options=--hide-successes`,
  `cabal build --builddir=.build all --ghc-options=-Werror`, and `./.build/prodbox dev check`.
- The May 13, 2026 `./.build/prodbox test all` run restored the supported runtime, reached
  `CLASSIFICATION=ready-for-external-proof` in `prodbox host public-edge`, passed the Cabal
  `prodbox-unit` and `prodbox-integration` suites, and reached the final lifecycle validation.
  The aggregate exited non-zero during AWS test-stack cleanup when `pulumi destroy --stack
  aws-test` returned AWS `AuthFailure` while waiting on EC2 instance deletion. The AWS test-stack
  destroy path now matches the EKS destroy path by refreshing Pulumi state and retrying destroy
  once before reporting failure.
- A later May 13, 2026 `./.build/prodbox test all` rerun completed successfully. The shared AWS
  setup path proves STS-federated operational credentials from the temporary-admin test identity,
  waits
  for repeated Route 53 stability on the dedicated IAM-user key, persists the IAM-user key for
  runtime because cert-manager Route 53 DNS01 credentials do not support an STS session-token
  field, proves `CLASSIFICATION=ready-for-external-proof`, completes the AWS EKS and HA RKE2
  validations, destroys the AWS substrate's Pulumi stacks, and clears operational `aws.*` before
  returning.

### Current Validation State

- `runGatewayDaemon` now builds a daemon `Env`, installs SIGTERM/SIGINT/SIGHUP handlers, marks
  readiness through `Starting` / `Ready` / `Draining`, and runs the heartbeat, ownership,
  DNS-write, REST, peer-listener, peer-dialer, and reload workers through the restricted
  `withAsync` / `race` / `concurrently` set.
- Worker entrypoints are wrapped by `runWorkerWithRetry`, which uses the shared `RetryPolicy`
  calculation, classifies retry decisions through `AppError`, and treats cancellation during
  `Draining` as intentional shutdown.
- The REST and peer listeners acquire sockets through `bracketOnError`; the REST listener stays
  available during the drain window so `/readyz` reports `503 draining`, while the peer listener
  stops accepting new work.
- The graceful-drain deadline defaults to 30 seconds and is read from `envLiveConfig` so the
  daemon can adopt the live override without restart.
- `gateway_daemon_acquire` is now a registry-owned prerequisite root, and `gateway start` gates the
  acquire phase through `fromRootIds` plus `runEffectDAG` before entering the daemon runtime.

### Remaining Work

None.

## Sprint 2.10: /healthz, /readyz, /metrics Endpoints [✅ Done]

**Status**: Done
**Implementation**: `src/Prodbox/Gateway/Daemon.hs`, `src/Prodbox/CheckCode.hs`, `test/daemon-lifecycle/Main.hs`, `test/golden/daemon-health/`
**Independent Validation**: real loopback daemon endpoint tests, response goldens, and source guards
prove constant-time health/readiness plus the typed metrics registry without Kubernetes or a later
phase.
**Docs to update**: `documents/engineering/distributed_gateway_architecture.md`

### Objective

Adopt [distributed_gateway_architecture.md#daemon-lifecycle](../documents/engineering/distributed_gateway_architecture.md#daemon-lifecycle).

### Deliverables

- Expose `/healthz`, `/readyz`, and `/metrics` (Prometheus exposition format) alongside the
  existing `/v1/state` surface in `src/Prodbox/Gateway/Daemon.hs`.
- `/readyz` returns 200 only after `serve` is entered and 503 during drain.
- Golden tests over response shapes in `prodbox-daemon-lifecycle` (per
  [Daemon Lifecycle Tests](../documents/engineering/README.md)and
  `Test Categories → Daemon Lifecycle Tests` §2252–2253). The captured fixtures cover
  `/healthz`, `/readyz` in ready and draining states, and `/metrics` exposition form.
- Filesystem readiness markers and `sd_notify(READY=1)` are explicitly forbidden; the
  HTTP `/readyz` endpoint is the only supported readiness signal per
  [Lifecycle](../documents/engineering/README.md). A
  `prodbox-haskell-style` rule refuses any reintroduction of those forbidden surfaces.
- Add `envMetrics :: MetricsRegistry` as a typed field on the daemon `Env` record per
  [distributed_gateway_architecture.md#daemon-lifecycle](../documents/engineering/distributed_gateway_architecture.md#daemon-lifecycle). The `/metrics` endpoint reads counter
  values from `envMetrics`; module-local mutable counter state (top-level `IORef`,
  `MVar`, or hidden registry) is forbidden via a custom `.hlint.yaml` rule extending
  the negative-space rules introduced by Sprint 1.19.

### Validation

1. Lifecycle test (Sprint 2.14) asserts `/readyz` flips through the expected states.
2. `/metrics` exposes the doctrine's minimum daemon counters.
3. Golden tests over `/healthz`, `/readyz`, and `/metrics` response shapes pass on a clean
   tree and visibly diff when the response surface changes.
4. Introducing a module-local mutable counter (top-level `IORef`/`MVar` outside `Env`)
   under `src/Prodbox/Gateway/` fails `prodbox dev lint haskell` with the negative-space
   rule that backs `envMetrics`.

### Current Validation State

- `cabal test --builddir=.build prodbox-daemon-lifecycle --test-options=--hide-successes` passes
  with `/healthz`, ready/draining `/readyz`, and normalized `/metrics` response-shape goldens.
- `cabal test --builddir=.build prodbox-haskell-style --test-options=--hide-successes` passes
  with the filesystem-readiness, `sd_notify`, reload-trigger, mutable-metrics, and daemon Async
  primitive markers enforced through `src/Prodbox/CheckCode.hs`.

### Remaining Work

None.

## Sprint 2.11: BootConfig / LiveConfig Split with Mounted-Dhall File-Watch Reload [✅ Done]

**Status**: Done — implementation landed via Sprints 2.20 (daemon Dhall settings
module) and 2.21 (file-watch trigger + drain-and-exit; live closure 2026-06-02).
Under [config_doctrine.md §7–§8](../documents/engineering/config_doctrine.md#7-file-watch-reload-trigger),
the daemon watches its `--config` Dhall path via fsnotify, re-decodes via
`Dhall.inputFile auto` on change, atomic-swaps `envLiveConfig` for LiveConfig-only
diffs, and drains-and-exits for any BootConfig diff so the kubelet restarts the
Pod. The legacy SIGHUP handler, the `config_boot_changes_ignored` "ignore and
continue" branch, and the JSON-flat-compat schema branch are removed; see
[legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md).
**Implementation**: `src/Prodbox/Gateway/Daemon.hs`, `src/Prodbox/Gateway/Types.hs`
**Independent Validation**: pure boot/live diff classification, daemon-lifecycle reload/drain tests,
and the recorded home file-watch exercise validate the mounted-Dhall contract on this phase's own
surface; no later phase is required.
**Docs to update**: `documents/engineering/distributed_gateway_architecture.md`,
`documents/engineering/aws_integration_environment_doctrine.md`

### Objective

Adopt [distributed_gateway_architecture.md#daemon-lifecycle](../documents/engineering/distributed_gateway_architecture.md#daemon-lifecycle).

### Deliverables

- Split `DaemonConfig` into immutable `BootConfig` fields (listen host/port, cert/key/CA
  paths, peer transport, schema version) and hot-reloadable `LiveConfig` fields (log level,
  intervals, feature flags).
- Store live config as `envLiveConfig :: TVar LiveConfig`. SIGHUP enqueues a reload through a
  dedicated `withAsync` worker that re-parses Dhall, validates `schemaVersion`, atomically
  swaps the `TVar`, and emits a `config_reloaded` structured log event.
- Reload rejections (boot-field changes, parse failures, schema mismatch) keep the running
  config and emit `config_reload_failed`, `config_boot_changes_ignored`, or
  `config_schema_mismatch`.
- Live-config consumers re-read `readTVarIO envLiveConfig` at each use site and never cache
  the dereferenced value across `await`/`yield`, per
  [distributed_gateway_architecture.md#daemon-lifecycle](../documents/engineering/distributed_gateway_architecture.md#daemon-lifecycle). Reviewed surfaces (`heartbeatLoop`,
  `gatewayLoop`, `dnsWriteLoop`, `peerListenerLoop`, `peerDialerLoop`) are enumerated as
  Sprint deliverables so the discipline is auditable.
- Reload step 8 publishes on an STM broadcast channel (`TChan` or `TBQueue`) so
  subscribers that derive internal state from `LiveConfig` — rate limiters, routing
  caches, anywhere a worker precomputes from live values — can refresh, per
  [distributed_gateway_architecture.md#daemon-lifecycle](../documents/engineering/distributed_gateway_architecture.md#daemon-lifecycle). The broadcast channel is exposed
  through `Env`; subscribers `atomically` block on it inside their own loops without
  polling.
- The on-disk Dhall configuration file follows the prescribed shape per
  [distributed_gateway_architecture.md#daemon-lifecycle](../documents/engineering/distributed_gateway_architecture.md#daemon-lifecycle): a `./types.dhall` plus
  `./defaults.dhall` import, a top-level `schemaVersion : Natural`, and `boot` / `live`
  sub-records mirroring the `BootConfig` / `LiveConfig` Haskell split.
  Operators editing the prodbox-config.dhall now produce a doctrine-conformant shape
  without ad-hoc layout drift.
- Sprint 0.4 round-3 extension: add `fsnotify`, `inotify`, and `mtime` polling to
  the forbidden reload-trigger set; SIGHUP via the dedicated `TBQueue ()` worker
  is the only sanctioned trigger per
  [distributed_gateway_architecture.md#daemon-lifecycle](../documents/engineering/distributed_gateway_architecture.md#daemon-lifecycle). The `.hlint.yaml`
  negative-space set (Sprint 1.19) and the `forbiddenPathRegistry` (Sprint 1.10)
  each grow rules refusing imports of `System.FSNotify`,
  `System.INotify`/`Linux.INotify`, and any reachable `getModificationTime` /
  `mtime` polling loop inside `src/Prodbox/Gateway/` or `src/Prodbox/Workload.hs`.
- Sprint 0.4 round-3 extension: bind the typed Dhall field
  `schemaVersion : Natural` as the top-level required field; a `schemaVersion`
  mismatch during reload is treated as a parse failure per
  [distributed_gateway_architecture.md#daemon-lifecycle](../documents/engineering/distributed_gateway_architecture.md#daemon-lifecycle). The reload worker emits
  `config_schema_mismatch` and keeps the running config rather than partially
  applying the mismatched values.
- Sprint 0.4 round-3 extension: bind the eight-step reload procedure step-by-step
  per [distributed_gateway_architecture.md#daemon-lifecycle](../documents/engineering/distributed_gateway_architecture.md#daemon-lifecycle):
  1. Read the config path from `BootConfig`.
  2. `Dhall.inputFile` parse + typecheck + decode against the
     `Prodbox.Daemon.Config` schema type.
  3. On parse / typecheck / decode failure: log warn, keep the current
     `LiveConfig`, emit `config_reload_failed`.
  4. If `BootConfig` fields differ from the running value: log warn that they are
     ignored, keep `BootConfig`, still apply the `LiveConfig` portion of the new
     value, emit `config_boot_changes_ignored`.
  5. Validate `schemaVersion`; mismatch is handled as a parse failure (step 3)
     plus the `config_schema_mismatch` event from the binding above.
  6. `atomically (writeTVar envLiveConfig newLiveConfig)` to swap atomically.
  7. Emit `config_reloaded` with a diff summary of the changed `LiveConfig`
     fields.
  8. Publish on the STM broadcast channel so subscribers refresh.
  The `prodbox-daemon-lifecycle` stanza (Sprint 2.14) exercises each step
  individually so a regression in any step surfaces a distinct test name.

### Validation

1. Lifecycle test sends SIGHUP after writing a modified Dhall config and asserts only the
   live portion takes effect.
2. Boot-field reloads are explicitly rejected with the doctrine's structured log event.
3. A unit test asserts every live-config consumer reads `readTVarIO envLiveConfig` at use
   site (text-search proof against the enumerated surfaces).
4. A subscriber registered against the broadcast channel observes a refresh event after a
   successful reload; the lifecycle test exercises this assertion alongside the live-
   field swap.
5. `prodbox dev check` (Sprint 1.23 doctrine-alignment scan) recognizes the prescribed
   `types.dhall` / `defaults.dhall` / `boot` / `live` shape and rejects any committed
   defaults file that diverges from the doctrine-named layout.

### Current Validation State

- The daemon now stores live intervals, clock-skew, log-level, and drain-deadline fields in
  `envLiveConfig :: TVar LiveConfig`; SIGHUP enqueues a reload worker; successful reloads swap
  the TVar and publish on `envLiveConfigReloads :: TChan LiveConfig`.
- Live consumers reread `envLiveConfig` at their use sites for heartbeat, ownership, DNS-write,
  peer-ingest, peer-dial, and drain timing.
- `src/Prodbox/Gateway/Types.hs` now accepts a structured JSON gateway config with top-level
  `schemaVersion`, `boot`, and `live` records while preserving flat JSON compatibility, and
  mismatched versions surface as `config_schema_mismatch` through the reload path.
- `src/Prodbox/Gateway.hs` emits the structured gateway config template with boot-only
  `dns_write_gate` fields and live reloadable timing or log-level fields.
- The implemented runtime shape is the supported daemon config contract for this phase.

### Remaining Work

None.

## Sprint 2.12: Structured JSON Logging via co-log [✅ Done]

**Status**: Done (with May 24, 2026 revision note: the LiveConfig log-level refresh
contract survives unchanged; the trigger relabels from "SIGHUP reload" to "file-watch
reload" per [config_doctrine.md §7](../documents/engineering/config_doctrine.md#7-file-watch-reload-trigger)).
The STM broadcast channel `envLiveConfigReloads` and the per-log-site
`readTVarIO envLiveConfig` reads stay verbatim; only the upstream reload-worker's input
source changes from `installHandler sigHUP` to the file watcher in Sprint 2.21.
**Implementation**: `src/Prodbox/Gateway/Logging.hs`, `src/Prodbox/Gateway/Daemon.hs`,
`src/Prodbox/Workload.hs`, `src/Prodbox/CheckCode.hs`, `test/daemon-lifecycle/Main.hs`,
`test/haskell-style/Main.hs`
**Independent Validation**: pure severity/rendering tests, daemon-lifecycle stderr capture, and
Haskell source guards prove structured logging and reload-sensitive filtering without a later phase.
**Docs to update**: `documents/engineering/distributed_gateway_architecture.md`,
`documents/engineering/code_quality.md`

### Objective

Adopt [distributed_gateway_architecture.md#daemon-lifecycle](../documents/engineering/distributed_gateway_architecture.md#daemon-lifecycle).

### Deliverables

- Adopt `co-log` as the daemon logger; replace ad-hoc logging with the doctrine's typed-field
  helper (`field`, `logInfo`, `logWarn`, `logError`).
- Daemon logs are JSON to stderr; stdout is reserved for protocol surfaces or unused.
- Forbid `putStrLn` / `Text.IO.hPutStrLn` in daemon code paths via a custom hlint rule and a
  legacy-ledger entry.
- The daemon log level is set by `BootConfig` at startup (with the CLI flag > env var >
  Dhall default > built-in default precedence rule from Sprint 2.15) and **refreshed
  from `LiveConfig` on every hot reload** per [distributed_gateway_architecture.md#daemon-lifecycle](../documents/engineering/distributed_gateway_architecture.md#daemon-lifecycle). The reload
  worker scheduled by Sprint 2.11 sets the new level on the `co-log` logger inside its
  atomic-swap step, so every subsequent log call observes the refreshed level without
  cached state.
- Sprint 0.4 round-3 extension: bind the typed field helper API on the daemon
  logging module per
  [distributed_gateway_architecture.md#daemon-lifecycle](../documents/engineering/distributed_gateway_architecture.md#daemon-lifecycle). `src/Prodbox/Gateway/Logging.hs`
  (or the dedicated daemon logging module) exposes
  `field :: (Aeson.ToJSON a) => Text -> a -> (Text, Aeson.Value)` for typed
  structured-log field construction plus the convenience wrappers
  `logStructured :: Severity -> Text -> [(Text, Aeson.Value)] -> App ()`,
  `logDebug`, `logInfo`, `logWarn`, and `logError` (each a thin specialization
  of `logStructured`). Daemon code never constructs an `Aeson.Object` inline at
  a log site; every structured field flows through `field` so the type is enforced
  at compile time. A `prodbox-haskell-style` rule refuses
  `Aeson.object` / `Aeson.fromList` invocations inside daemon-path log calls.

### Validation

1. Lifecycle test asserts structured JSON shape on stderr.
2. The forbidden-call hlint rule blocks reintroduction of `putStrLn` in
   `src/Prodbox/Gateway/`.
3. The lifecycle test sends SIGHUP after writing a config with a changed live
   `log_level` value and asserts subsequent log filtering reflects the new level
   without restart.

### Current Validation State

- `cabal test --builddir=.build prodbox-daemon-lifecycle --test-options=--hide-successes`
  passes with the structured stderr JSON and hot-reload log-level assertions.
- `cabal test --builddir=.build prodbox-haskell-style --test-options=--hide-successes`
  passes with the `co-log` dependency-boundary and negative-space checks.
- `./.build/prodbox dev check` passes after formatting the touched Haskell sources.
- The broader `./.build/prodbox test all` aggregate was intentionally paused by operator
  request after reaching the integration chart-reconcile path; Sprint 2.12's listed validation
  had already passed.

### Remaining Work

None.

### Closure Notes

Gateway and workload daemon entrypoints emit structured JSON through the co-log-backed logging
module; gateway log sites read `envLiveConfig` at emission time so SIGHUP reloads update the
threshold for later calls. `prodbox-daemon-lifecycle` covers the stderr JSON envelope plus the
hot-reload log-level path, and `prodbox-haskell-style` / `prodbox dev check` guard the
dependency boundary, direct terminal writes, and inline log-object construction.

## Sprint 2.13: Test Hooks in Env, At-Least-Once Formalization [✅ Done]

**Status**: Done (with May 24, 2026 revision note: the daemon `Env` hook contract is
unchanged; the lifecycle test stanza extends in Sprint 2.21 to cover the new file-watch
reload trigger as well as the SIGHUP-based reload trigger it supersedes, per
[unit_testing_policy.md](../documents/engineering/unit_testing_policy.md) "Daemon
lifecycle tests" row).
**Implementation**: `src/Prodbox/Gateway/Daemon.hs`, `src/Prodbox/Daemon/Events.hs`
**Independent Validation**: injected-hook unit/process tests and deterministic `Daemon.Events`
record/process tables validate the test seam and durable at-least-once pattern without external
services or a later phase.
**Docs to update**: `documents/engineering/unit_testing_policy.md`,
`documents/engineering/distributed_gateway_architecture.md`

### Objective

Adopt [distributed_gateway_architecture.md#test-hooks-in-env](../documents/engineering/distributed_gateway_architecture.md#test-hooks-in-env) and
`At-Least-Once Event Processing`.

### Deliverables

- Extend the daemon `Env` with no-op-in-production hook fields
  (`envAfterPeerEventCommit`, `envBeforeOrdersAdoption`, `envOnPeerConnectionEstablished`,
  and any timing-sensitive points currently relying on `threadDelay`).
- Replace `threadDelay`-based test waits with hook injection.
- Make the durable `Prodbox.Daemon.Events` at-least-once contract explicit: every persisted event
  carries a processed marker, handlers are documented idempotent, and replay orders by
  `created_at ASC`. Gateway peer anti-entropy is a separate bounded in-memory protocol under Sprint
  `2.31`, not a durable event log.
- Sprint 0.4 round-3 extension: bind the production-no-op / test-injected hook
  contract pattern explicitly per
  [distributed_gateway_architecture.md#daemon-lifecycle](../documents/engineering/distributed_gateway_architecture.md#daemon-lifecycle). Every hook field on the daemon `Env`
  has a no-op default that production startup installs unchanged; tests override
  the default at `Env` construction only. A `prodbox-haskell-style` rule and a
  `prodbox-unit` assertion together enforce that no module under
  `src/Prodbox/Gateway/` (or any other daemon path) reads a hook field except
  through the `Env` it was injected into, and that the production startup path
  constructs `Env` with the no-op values literally (so tests cannot accidentally
  leak instrumented hooks into a production binary).

### Validation

1. `prodbox-unit` / `prodbox-integration` tests rely only on hooks for timing-sensitive
   assertions.
2. Replaying an already-processed peer event is a no-op at the handler boundary.

### Current Validation State

- The daemon `Env` now carries no-op production hooks for peer-event commits, Orders adoption,
  and peer-connection establishment; peer ingestion calls the commit hook after the STM state
  update.
- The at-least-once helper module now carries the handler idempotency precondition and
  `processed_at` tracking for future daemon consumers.
- `src/Prodbox/CheckCode.hs` now enforces that production startup constructs the daemon `Env`
  with literal `noopDaemonHooks` and that daemon hook fields are read through the injected
  `envHooks env` value rather than through out-of-band state.
- Timing-sensitive black-box lifecycle assertions that cross a real process boundary are kept on
  HTTP readiness and signal observation; hook fields remain available for in-process daemon tests
  without leaking into production startup.

### Remaining Work

None.

## Sprint 2.14: prodbox-daemon-lifecycle Test Stanza [✅ Done]

**Status**: Done
**Implementation**: `prodbox.cabal`, `test/daemon-lifecycle/Main.hs`, `src/Prodbox/Gateway.hs`, `src/Prodbox/Workload.hs`
**Independent Validation**: the dedicated process stanza starts the real built daemon and proves
health, readiness, metrics, graceful SIGTERM drain, and forced second-SIGTERM exit locally with no
cluster or later-phase dependency.
**Docs to update**: `documents/engineering/unit_testing_policy.md`

### Objective

Adopt [Daemon Lifecycle Tests](../documents/engineering/README.md) and
`Test Organization`.

### Deliverables

- New `test-suite prodbox-daemon-lifecycle` stanza with `type: exitcode-stdio-1.0`. Spawn the
  daemon via `typed-process`, poll `/readyz`, exercise the protocol surface, send SIGTERM,
  assert graceful drain within the configured deadline, assert exit `0`.
- Assert the two-SIGTERM shutdown contract from
  [Daemon Lifecycle Tests](../documents/engineering/README.md)and
  §2254: single SIGTERM begins drain and the daemon exits `0` within the deadline; a
  second SIGTERM (or the drain deadline) forces exit. The test exercises both branches:
  graceful drain on the first signal, forced exit on the second.
- Health-endpoint response shapes belong in daemon-lifecycle golden tests (Sprint 2.10).
- Forbid `terminateProcess` without prior graceful shutdown, `threadDelay`-based readiness
  probes, and filesystem readiness markers.
- Sprint 0.4 round-3 extension: capture the `/healthz`, `/readyz`, and `/metrics`
  response shapes as golden tests inside the `prodbox-daemon-lifecycle` stanza per
  [unit_testing_policy.md#test-categories](../documents/engineering/unit_testing_policy.md#test-categories)and `Long-Running Daemons in the Same
  Binary → Health Endpoints`. The captured fixtures assert:
  - `/healthz` returns `200 OK` with the doctrine's alive body once the daemon
    enters `serve`,
  - `/readyz` returns `200 OK` with the doctrine's ready body once `serve` is
    entered, and `503 Service Unavailable` with the doctrine's draining body
    after the first SIGTERM,
  - `/metrics` returns the Prometheus-exposition-format text with the daemon's
    minimum counter set (the counters bound by `envMetrics` in Sprint 2.10).
  The golden capture lives under `test/golden/daemon-health/`. The endpoint implementations
  closed under Sprint 2.10; this extension owns the lifecycle-stanza capture.

### Validation

1. `cabal test prodbox-daemon-lifecycle` succeeds on a clean worktree.
2. Forbidden test patterns are absent (enforced via the lint stack from Sprint 1.10).
3. The two-SIGTERM assertion exercises both graceful-drain and forced-exit branches and
   surfaces a distinct test name for each branch so a regression is visible in test
   summaries.

### Current Validation State

- The `prodbox-daemon-lifecycle` stanza now spawns the built `prodbox gateway start` process,
  polls `/readyz` through `retryServiceAction`, asserts `/healthz` and `/metrics`, sends
  SIGTERM, observes `503 draining`, and verifies `ExitSuccess` after the configured drain
  deadline.
- The stanza also exercises the second-SIGTERM branch with a distinct test name and keeps the
  daemon CLI/env precedence coverage from Sprint 2.15.
- The process driver now uses the repository's typed subprocess boundary, and the endpoint
  response shapes are captured under `test/golden/daemon-health/`.
- `src/Prodbox/CheckCode.hs` and `test/haskell-style/Main.hs` now reject direct `threadDelay`
  and raw `terminateProcess` usage in the daemon-lifecycle stanza.

### Remaining Work

None.

## Sprint 2.15: Daemon CLI Plumbing — `--config <path>` Only [✅ Done]

**Status**: Done — implementing code work landed via Sprints 1.28 (env-var-read lint
rule + `PRODBOX_LOG_LEVEL` / `PRODBOX_CONFIG_PATH` / `PRODBOX_PORT` removal from
`src/Prodbox/Gateway.hs`), 2.20 (Dhall settings module), and 2.21 (file-watch trigger
+ drain-and-exit; live closure 2026-06-02). Under
[config_doctrine.md §2 and §10](../documents/engineering/config_doctrine.md#2-single-dhall-surface-per-binary-instance),
`prodbox gateway start` and `prodbox workload start` accept exactly one startup-time
CLI knob — `--config <path>`. The `--log-level`, `--port`, `--node-id`, `--foreground`,
and `--detach` flags are not supported; every value the daemon needs lives in the
Dhall file. The legacy `PRODBOX_*` env-var precedence ladder is removed; see
[legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md).
**Implementation**: `src/Prodbox/CLI/Parser.hs`, `src/Prodbox/CLI/Spec.hs`, `src/Prodbox/Gateway.hs`, `src/Prodbox/Workload.hs`, `test/daemon-lifecycle/Main.hs`
**Independent Validation**: parser-roundtrip and generated-help tests plus the daemon-lifecycle
fixture prove `--config <path>` is the sole startup knob and rejected alternatives fail before
execution; no later phase is involved.
**Docs to update**: `documents/engineering/cli_command_surface.md`,
`documents/engineering/distributed_gateway_architecture.md`,
`documents/engineering/aws_integration_environment_doctrine.md`

### Objective

Adopt [distributed_gateway_architecture.md#daemon-lifecycle](../documents/engineering/distributed_gateway_architecture.md#daemon-lifecycle) so every daemon-launching `prodbox` command exposes the
doctrine's standard flag set with the prescribed startup-precedence rule.

### Deliverables

- Replace the positional `<config-path>` argument on `prodbox gateway start` and
  `prodbox gateway status` with `--config <path>`, declared in the `CommandSpec` registry
  (Sprint 1.6). Daemons refuse to start on missing or unparseable config.
- Add `--log-level <level>`, `--port <int>`, and `--foreground` flags on every daemon-
  launching command (`prodbox gateway start`, `prodbox workload start`). `--foreground` is
  the default per [CLI-to-Daemon Plumbing](../documents/engineering/README.md)and self-daemonization (double-fork, `setsid`, `forkProcess`) is forbidden;
  the daemon rejects `--detach` per the doctrine's supervisor-owned process model. A
  `prodbox-haskell-style` unit test asserts no daemon-path module imports
  `System.Posix.Process` `forkProcess` or invokes `setsid` directly (paired with the
  parser-side enforcement landed in Sprint 1.23).
- Add `PRODBOX_LOG_LEVEL`, `PRODBOX_CONFIG_PATH`, and `PRODBOX_PORT` env-var overrides
  limited to `BootConfig` defaults (Sprint 2.11). Document the precedence rule: CLI flag >
  env var > Dhall file default > built-in default.
- Update `documents/engineering/cli_command_surface.md` so the canonical daemon flag set
  and env-var precedence are explicit on the supported surface.
- Enqueue the positional-`<config-path>` parser shape in
  [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md) `Pending Removal` with
  Sprint 2.15 as owner.

### Validation

1. `prodbox gateway start --config <path>` and the env-var path agree at startup; the
   in-process `BootConfig` reflects the precedence rule.
2. `prodbox gateway start` exits non-zero with a doctrine-style three-element error message
   when `--config` points at a missing or unparseable file.
3. The `prodbox-daemon-lifecycle` stanza (Sprint 2.14) exercises both flag and env-var
   startup paths.

### Remaining Work

None.

## Sprint 2.16: At-Least-Once Event-Processing Module [✅ Done]

**Status**: Done
**Implementation**: `src/Prodbox/Daemon/Events.hs`, `test/unit/Main.hs`
**Independent Validation**: deterministic in-memory event-store tables and repeated
`processEvents` properties prove record/fetch/first-mark/idempotent replay semantics without a
database, live infrastructure, or a later phase.
**Docs to update**: `documents/engineering/distributed_gateway_architecture.md`,
`documents/engineering/effect_interpreter.md`, `documents/engineering/pure_fp_standards.md`,
`documents/engineering/unit_testing_policy.md`

### Objective

Formalize the durable at-least-once event-processing pattern from
[streaming_doctrine.md#9-at-least-once-event-processing](../documents/engineering/streaming_doctrine.md#9-at-least-once-event-processing)
so daemon event-consuming surfaces share one canonical module rather than ad-hoc per-call-site
patterns. Gateway peer anti-entropy deliberately remains a separate bounded in-memory semantic
protocol; it does not adopt the durable processed-marker store.

### Deliverables

- New module `src/Prodbox/Daemon/Events.hs` exposing:
  - `data StoredEvent = StoredEvent { eventId :: EventId, eventAggregateId :: AggregateId,
    eventType :: EventType, eventPayload :: Aeson.Value, eventCreatedAt :: UTCTime,
    eventProcessedAt :: Maybe UTCTime }` matching doctrine §1653–1660.
  - `newtype EventHandler = EventHandler (StoredEvent -> IO ())` with the idempotency
    precondition encoded in the haddock comment per doctrine §1720.
  - `recordEvent`, `markEventProcessed`, `fetchUnprocessedEvents`, and a top-level
    `processEvents` consumer that fetches unprocessed events, invokes the handler, marks each
    `processed_at`, and returns the count processed.
- `documents/engineering/distributed_gateway_architecture.md` records why gateway peer-state
  anti-entropy uses the bounded in-memory cursor/delta/repair protocol rather than the durable
  database-backed `processed_at` form.
- `documents/engineering/pure_fp_standards.md` cross-references
  `src/Prodbox/Daemon/Events.hs` as the canonical at-least-once pattern for any future
  daemon event-consumer.
- Enqueue any pre-doctrine event-processing call site under `src/Prodbox/Gateway/` or
  `src/Prodbox/Workload.hs` that does not consume the new module in
  [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md) `Pending Removal`
  with Sprint 2.16 as owner.

### Validation

1. `cabal test prodbox-unit` covers the `recordEvent` / `markEventProcessed` /
   `fetchUnprocessedEvents` triad against a deterministic clock test hook (Sprint 2.13).
2. A property test asserts that running `processEvents` twice in a row over the same set
   of unprocessed events is a no-op on the second invocation (idempotent-replay
   contract).
3. The `documents/engineering/distributed_gateway_architecture.md` correspondence section
   distinguishes the bounded gateway anti-entropy protocol from this durable event-store module.

### Current Validation State

- `src/Prodbox/Daemon/Events.hs` exposes `StoredEvent`, `EventId`, `AggregateId`,
  `EventType`, `EventHandler`, `recordEvent`, `markEventProcessed`,
  `fetchUnprocessedEvents`, and `processEvents` over a deterministic in-memory `EventStore`.
- `prodbox-unit` covers event recording, duplicate suppression by event id, processed-state
  filtering, chronological replay, and idempotent second `processEvents` runs.
- `documents/engineering/distributed_gateway_architecture.md` records that gateway peer state uses
  bounded in-memory cursor/delta/repair anti-entropy while durable event consumers use
  `Prodbox.Daemon.Events`.

### Remaining Work

None.

## Sprint 2.17: Native Haskell HTTP Client Replaces curl Shell-outs [✅ Done]

**Status**: Done (May 23, 2026) on the typed HTTP-client and Phase-2 gateway/DNS caller surface.
**Implementation**: new `src/Prodbox/Http/Client.hs` (wrapping `Network.HTTP.Client` + `Network.HTTP.Client.TLS`); new `src/Prodbox/Gateway/Client.hs` (typed gateway calls reusing `PeerEndpoint`); rewrites in `src/Prodbox/Gateway.hs` (`queryGatewayState`), `src/Prodbox/Gateway/Daemon.hs` (`fetchPublicIp`), `src/Prodbox/Dns.hs` (`fetchPublicIp`), `src/Prodbox/Infra/AwsEksTestStack.hs` (`fetchPublicIpv4`), `src/Prodbox/Infra/AwsTestStack.hs` (`fetchPublicIpv4`); 10 new unit tests in `test/unit/Main.hs::"Sprint 2.17 Haskell HTTP client"`
**Independent Validation**: pure request/error classification and fake HTTP-server tests plus the
built CLI gateway/DNS paths validate the typed client and migrated Phase-2 callers without a later
phase. Surviving non-Phase-2 host `curl` sites remain explicit ledger cleanup, not this sprint's work.
**Docs to update**: `documents/engineering/secret_derivation_doctrine.md` (host↔cluster contract), `documents/engineering/cli_command_surface.md`, [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md)

### Objective

Introduce the native Haskell HTTP boundary and migrate the Phase-2 gateway, DNS, and public-IP
callers away from host `curl` subprocesses. The repo-wide residual host-curl cleanup remains
separately visible in the legacy ledger and does not expand this completed sprint's owned surface.

### Deliverables

- New module `src/Prodbox/Http/Client.hs` exposing `httpGetJson`, `httpPostJson`,
  `httpGetBytes`, each returning `Either HttpError a`, sharing a singleton
  `Network.HTTP.Client.Manager` reused across calls, and accepting per-call timeouts.
  Error ADT distinguishes `HttpConnectionRefused`, `HttpTimeout`,
  `HttpStatus Int`, and `HttpDecode String`.
- New module `src/Prodbox/Gateway/Client.hs` exposes typed gateway calls reusing `PeerEndpoint` and
  the shared REST URL construction. Historical secret-derivation RPC stubs were later removed by
  the Vault-native Sprint `3.19` cleanup.
- Curl call sites removed: `src/Prodbox/Gateway.hs:285-317`,
  `src/Prodbox/Gateway/Daemon.hs:1341-1360`, `src/Prodbox/Dns.hs:108-124`, and the
  AWS public-IP helper callers named in `Implementation`. Remaining host call sites and
  `ToolCurl` stay governed by the explicit pending ledger row.
- 10+ unit tests in `test/unit/Main.hs::"Sprint 2.17 Haskell HTTP client"` covering
  the success path, 404, connection-refused, timeout, JSON-decode failure, manager
  reuse, and per-call timeout precedence.

### Validation

1. `prodbox dev check` exit 0 (verified May 23, 2026).
2. `prodbox dev lint docs` exit 0; `prodbox dev docs check` exit 0.
3. `prodbox test unit` 444/444 (up from 434 before this sprint).
4. The migrated host-side callers (`queryGatewayState`, `Dns.fetchPublicIp`,
   `Gateway/Daemon.fetchPublicIp`, `Infra/AwsEksTestStack.fetchPublicIpv4`,
   `Infra/AwsTestStack.fetchPublicIpv4`) all route through
   `Prodbox.Http.Client` and `Prodbox.Gateway.Client` rather than spawning
   `curl`.

### Remaining Work

- None. Sprint `2.17`'s typed client and Phase-2 caller surface is closed. The surviving repo-wide host
  subprocess sites remain a separate `Pending Removal` ledger item; pod-internal curl images, when
  required, are mirrored through the in-cluster `registry:2` service.

## Sprint 2.18: 127.0.0.1-Only NodePort Enforcement via Host Firewall [✅ Done]

**Status**: Done (May 23, 2026; full restrict/unrestrict and lifecycle wiring subsequently landed).
**Implementation**: `src/Prodbox/Host.hs` (new pure helpers `gatewayNodePortFirewallRuleArgs`, `gatewayNodePortFirewallCheckArgs`, `FirewallRuleAction`, `renderFirewallRuleAction`; effectful `runHostFirewallGatewayRestrict` using `iptables -C` then `iptables -A`); `src/Prodbox/CLI/Command.hs` (new `HostFirewallGatewayRestrict Int` constructor); `src/Prodbox/CLI/Spec.hs` (`gatewayNodePortParser`, new `host firewall gateway-restrict` arm, `group`-promoted `firewall` CommandSpec); regenerated `share/man/man1/prodbox-host.1`, `share/completion/{bash,zsh,fish}/prodbox*`, `documents/cli/commands.md`
**Independent Validation**: pure iptables argument/action tables and parser/generated-command tests
prove idempotent restrict/unrestrict construction locally; the recorded home exercise proves the
loopback-only NodePort boundary without a later-phase dependency.
**Docs to update**: `documents/engineering/secret_derivation_doctrine.md`, `documents/engineering/distributed_gateway_architecture.md`, `documents/engineering/cli_command_surface.md`

### Objective

Restrict the gateway-service NodePort to loopback ingress on the operator host. This
is the security boundary that makes the host-CLI-to-gateway HTTP path safe without
introducing TLS; external traffic (LAN, WAN) is dropped at the host firewall before
reaching the cluster. See
[secret_derivation_doctrine.md §5](../documents/engineering/secret_derivation_doctrine.md)
for the authoritative contract.

### Deliverables

- Pure rule helpers `gatewayNodePortFirewallRuleArgs :: Int -> [String]`
  (iptables `-A INPUT ! -i lo -p tcp --dport <port> -j DROP -m comment
  --comment prodbox-gateway-nodeport-loopback-only`) and
  `gatewayNodePortFirewallCheckArgs :: Int -> [String]` (same shape with the
  leading `-A` swapped for `-C` so the install path can detect an already-
  present rule).
- `FirewallRuleAction` ADT (`FirewallRuleInstalled` /
  `FirewallRuleAlreadyPresent` / `FirewallRuleRemoved` /
  `FirewallRuleNotPresent`) with `renderFirewallRuleAction` for one-line
  operator-visible status.
- `runHostFirewallGatewayRestrict :: Int -> IO ExitCode` invokes `iptables
  -C` first; if the rule is present it reports `already-present` and
  exits 0; otherwise it invokes `iptables -A` and reports `installed`.
- `HostFirewallGatewayRestrict Int` constructor on `HostCommand` (`src/
  Prodbox/CLI/Command.hs`); new parser arm `["host", "firewall",
  "gateway-restrict"]` wired through `RunNative . NativeHost`.
- `gatewayNodePortParser :: Parser Int` exposing `--port PORT` with a
  pinned default of `30443`.
- CommandSpec promoted `host firewall` from a leaf to a `group` so the
  new `gateway-restrict` child surfaces in the regenerated manpage,
  shell completions, and `documents/cli/commands.md`.
- 7 new unit tests in `test/unit/Main.hs::"Sprint 2.18 host firewall
  gateway-restrict"` covering the rule-text contract, port embedding,
  comment-tag stability, the `-C` check-args derivation, and the
  `FirewallRuleAction` render shape.

### Validation

1. `prodbox dev check` exit 0 (verified May 23, 2026).
2. `prodbox dev lint docs` exit 0; `prodbox dev docs check` exit 0 after
   `prodbox dev docs generate` re-rendered the new subcommand surface.
3. `prodbox test unit` 451/451 (up from 444 after Sprint 2.17).

### Remaining Work

- None. The symmetric unrestrict command, lifecycle install/remove wiring, and home loopback-only
  exercise landed; later daemon API changes do not alter this host firewall boundary.

## Sprint 2.19: Gateway Daemon Secret-Derivation Service (Historical) [✅ Done]

**Status**: Done (2026-05-30 historical delivery; superseded and removed by the Vault-root
architecture in Sprints `3.18`/`3.19`).
**Implementation**: new `src/Prodbox/Secret/Derive.hs`, new `src/Prodbox/Secret/MasterSeed.hs`, `src/Prodbox/Gateway/Daemon.hs` HTTP server extensions, MinIO IAM bootstrap (Pulumi or one-shot Job), `charts/gateway/` Secret + Deployment volume mount additions, `Prodbox.Gateway.Client` extensions, `prodbox.cabal` dep addition
**Independent Validation**: the historical implementation passed its pure derivation, daemon RPC,
and home live tests at closure; current unit/source-absence tests prove the master-seed modules,
derive/ensure-namespace RPCs, and chart consumers stay removed, independently of later work.
**Docs to update**: `documents/engineering/secret_derivation_doctrine.md` (new SSoT — already created by Part 1 doctrine work), `documents/engineering/distributed_gateway_architecture.md`, `documents/engineering/storage_lifecycle_doctrine.md`, `documents/engineering/helm_chart_platform_doctrine.md`

> **Superseded architecture record.** Everything in this sprint's objective, deliverables,
> validation, and historical closure evidence below describes the May 2026 master-seed design at
> the time it was delivered. It is not the current gateway or secret architecture. Sprint `3.19`
> removed `Prodbox.Secret.MasterSeed`, the derive/ensure-namespace RPCs, derived chart secrets, and
> their callers; current secret authority is Vault KV through typed `SecretRef.Vault` values.

### Objective

The historical objective was to make the in-cluster gateway daemon the sole owner of a master seed
and the sole derivation authority for data-bound chart secrets. Sprint `3.19` supersedes this
objective with Vault-native materialization; the bullets below are retained only as delivery
evidence for the removed design.

### Deliverables

The following deliverables are historical and no longer exist on the supported path:

- New `Prodbox.Secret.Derive` (pure): `derive :: MasterSeed -> Text -> ByteString`
  (HMAC-SHA-256 with the context string as message). Typed context constructors
  (`patroniRoleContext :: Namespace -> Release -> PatroniRole -> Text`,
  `keycloakAdminContext`, `gatewayEventKeyContext`) returning canonical strings.
  20+ unit tests: determinism, context uniqueness, golden vectors against the
  doctrine table.
- New `Prodbox.Secret.MasterSeed` (gateway-side):
  `ensureMasterSeed :: MinioClient -> IO MasterSeed` reads-or-creates the
  `prodbox/master-seed` object under a list-then-put guard so concurrent first-start
  races do not produce two seeds. 8+ unit tests against a mocked S3 client.
- Gateway daemon endpoint extensions in `src/Prodbox/Gateway/Daemon.hs:761-858`:
  `GET /v1/secret/derive?context=<context>` and
  `POST /v1/secret/ensure-namespace`. Response shapes per
  [secret_derivation_doctrine.md §4](../documents/engineering/secret_derivation_doctrine.md).
  `ensure-namespace` returns Secret names + SHA-256 of each derived value (never
  plaintext).
- MinIO IAM bootstrap (one of: a Pulumi program addition, or a chart-deployed
  one-shot Job using MinIO root creds) creates the `prodbox-state` bucket, the
  `prodbox-gateway` MinIO user, and the policy granting only that user
  `s3:GetObject` / `s3:PutObject` / `s3:ListBucket` on the bucket. The
  raw Pulumi checkpoint layout remains separately owned by Sprint `7.14`.
- Gateway pod mounts `gateway-minio-creds` k8s Secret (created by the chart via
  Helm `lookup` + `randAlphaNum` on first install).
- `prodbox.cabal` adds `amazonka-s3` (or `minio-hs`) as a new dep for the native
  S3-compatible client.
- `Prodbox.Gateway.Client` (Sprint 2.17) extended with
  `derive :: PeerEndpoint -> Context -> IO (Either GatewayError ByteString)` and
  `ensureNamespace :: PeerEndpoint -> Namespace -> Release -> IO (Either
  GatewayError EnsureResult)`.
- 15+ daemon-side tests covering the three failure modes from
  [secret_derivation_doctrine.md §8](../documents/engineering/secret_derivation_doctrine.md);
  8+ client-side tests.

### Validation

1. `prodbox dev check` exit 0.
2. `prodbox test unit` covers all new tests.
3. Live regression on this host (one round of the verification block from the
   approved plan Part 3 step 2): `prodbox rke2 reconcile` materializes
   `prodbox/master-seed`; `curl http://127.0.0.1:<nodeport>/v1/secret/derive?
   context=patroni:keycloak:keycloak:app` returns a base64 value; a second
   identical call returns the same value;
   `prodbox rke2 delete --yes` + `prodbox rke2 reconcile` preserves the seed (same
   derived value as before).

### Historical Validation State (Superseded)

- `src/Prodbox/Secret/Derive.hs` (pure HMAC-SHA-256 derivation) exposes
  `MasterSeed` smart-constructor + `masterSeed` validator (rejects
  non-32-byte input), `derive`, `deriveBase64Url`, `deriveHex`, the
  `PatroniRole` ADT, and the three context-string constructors
  (`patroniRoleContext`, `keycloakAdminContext`, `gatewayEventKeyContext`)
  that match the doctrine table at
  [secret_derivation_doctrine.md §3](../documents/engineering/secret_derivation_doctrine.md).
  13 new unit tests in
  `test/unit/Main.hs::"Sprint 2.19 master-seed derivation"` cover
  determinism, context uniqueness, encoding widths, the redacted `Show`
  instance, and the doctrine table verbatim.
- `Show MasterSeed` is `"MasterSeed <redacted>"` so seed material never
  lands in operator-facing logs or test output.
- **Wire-contract layer landed May 23, 2026**: new
  `src/Prodbox/Secret/Wire.hs` exposes the typed request/response shapes
  for both endpoints (`DeriveResponse`, `EnsureNamespaceRequest`,
  `EnsureNamespaceResponse`, `SecretSha256Entry`) with explicit JSON
  derivations so the snake_case wire shape stays stable across record
  renames; `Prodbox.Gateway.Client` extends to typed
  `derive :: PeerEndpoint -> Text -> IO (Either GatewayError DeriveResponse)`
  and
  `ensureNamespace :: PeerEndpoint -> Text -> Text -> IO (Either GatewayError EnsureNamespaceResponse)`
  built on `Prodbox.Http.Client.httpGetJson` / `httpPostJsonResponseJson`
  (URL-encoded context query parameter for `derive`; standard
  `Content-Type: application/json` body for `ensureNamespace`);
  `Prodbox.Gateway.Daemon::handleRestClient` now routes
  `/v1/secret/derive*` and `/v1/secret/ensure-namespace` to structured
  `503 master-seed unavailable` responses per
  [secret_derivation_doctrine.md §8](../documents/engineering/secret_derivation_doctrine.md)
  while the MinIO IAM bootstrap + `MasterSeed` read/write remain
  scheduled. 8 new unit tests in
  `test/unit/Main.hs::"Sprint 2.19 gateway secret-endpoint wire types"`
  cover JSON round-trips for all three shapes, the canonical encoding
  pinning, the plaintext-never invariant, and the URL helpers'
  canonical strings.
- **Chart-side scaffolding landed May 23, 2026**: new
  `charts/gateway/templates/secret-minio-creds.yaml` materializes the
  `gateway-minio-creds` Opaque Secret using the `lookup`-guarded
  `randAlphaNum` pattern so the credentials survive helm upgrades — the
  username is `prodbox-gateway-<8-char-suffix>` and the password is 40
  random alphanumeric characters; both regenerate only when the Secret
  is absent. New `charts/gateway/templates/service-nodeport.yaml` adds a
  cluster-wide NodePort (`gateway-nodeport`) exposing the gateway
  daemon's REST port on `30443` by default (matching the Sprint 2.18
  iptables-rule default), selector intentionally omits `gateway-node`
  so any gateway pod in the release answers host-CLI requests. New
  `nodePort.rest` value in `charts/gateway/values.yaml` lets operators
  override the port if it collides with another NodePort on the host.
  `charts/gateway/templates/deployments.yaml` adds `MINIO_ACCESS_KEY_ID`
  / `MINIO_SECRET_ACCESS_KEY` env vars from the new Secret via explicit
  `valueFrom: secretKeyRef:` entries; the daemon ignores them today and
  the `/v1/secret/*` routes still serve the structured 503 placeholder
  per doctrine §8 until `Prodbox.Secret.MasterSeed` reads the vars.
  `helm template gateway charts/gateway` renders all three manifests
  cleanly; `prodbox dev check` chart-lint passes.
- **Symmetric firewall-rule removal landed May 23, 2026**: new
  `runHostFirewallGatewayUnrestrict :: Int -> IO ExitCode` in
  `src/Prodbox/Host.hs` mirrors the Sprint 2.18 install path — probes
  via `iptables -C` first, treats absent-rule as success-with-reason
  (`FirewallRuleNotPresent`), otherwise invokes `iptables -D` and
  reports `FirewallRuleRemoved`. Exposed via the new operator-facing
  `prodbox host firewall gateway-unrestrict --port PORT` subcommand
  (default port `30443`); generated CLI artifacts under
  `share/man/man1/prodbox-host.1`,
  `share/completion/{bash,zsh,fish}/prodbox*`, and
  `documents/cli/commands.md` regenerated via `prodbox dev docs generate`.
  The new `gatewayNodePortFirewallDeleteArgs :: Int -> [String]` pure
  helper mirrors `gatewayNodePortFirewallRuleArgs` verbatim except for
  the leading `-D` verb so the install and remove paths target the
  same rule (matched on the stable `prodbox-gateway-nodeport-loopback-only`
  comment tag).
- All three gates green: `prodbox dev check` exit 0,
  `prodbox dev lint docs` exit 0, `prodbox dev docs check` exit 0.
- `prodbox test unit` 497/497 (up from 495 after the new
  `host firewall gateway-unrestrict` subcommand added two auto-generated
  parser cases; 464 before Sprint 2.18 work).

### Historical Closure Evidence (Superseded)

The pure derivation surface, the wire-contract layer, and the
foundational `Prodbox.Secret.MasterSeed` MinIO read\/write module are
landed. The remaining sprint deliverables are coupled into one
live-exercise package:

1. **`Prodbox.Secret.MasterSeed`** (MinIO bucket read\/write,
   **Done May 23, 2026 later session**): new
   `src/Prodbox/Secret/MasterSeed.hs` exposes
   `MinioMasterSeedConfig` (endpoint URL + bucket + key + MinIO
   credentials), `MasterSeedError` ADT (`MasterSeedEntropyUnavailable`
   / `MasterSeedInvalidSize` / `MasterSeedSubprocessFailed` /
   `MasterSeedGetFailed` / `MasterSeedPutFailed` /
   `MasterSeedFileIoFailed`), `ensureMasterSeed` (read-or-create
   with `If-None-Match: *` concurrent-creation guard +
   post-PUT GET re-read so racing first-starts converge),
   `generateFreshSeedBytes` (32 bytes from `/dev/urandom`), and the
   pure `awsS3ApiHeadArgs` / `awsS3ApiGetArgs` / `awsS3ApiPutArgs`
   helpers plus `isAwsCliNoSuchKeyMessage` /
   `isAwsCliPreconditionFailedMessage` pattern matchers that pin the
   AWS CLI error-blob recognition surface. Shells out to `aws s3api`
   via `Prodbox.Service.runMinIOWithEnv` (no new `amazonka-s3` or
   `minio-hs` dependency required at this stage — the daemon already
   carries the AWS CLI in its container image). 14 new unit tests
   in `test/unit/Main.hs::"Sprint 2.19 MasterSeed MinIO read-write contract"`
   cover the wire-shape pinning, the doctrine-canonical object key,
   the `defaultMinioMasterSeedConfig` endpoint resolution, the six
   error renderings, both AWS-CLI message matchers, and live
   `/dev/urandom` invocation (32 bytes, distinct across calls). Test
   count 533/533 after the new cases. `prodbox dev check` exit 0.
2. **MinIO IAM bootstrap** (Done May 25, 2026): `prodbox rke2
   reconcile` runs `ensureGatewayMinioBootstrap`
   (`src/Prodbox/CLI/Rke2.hs`), which resolves the dedicated
   `prodbox-gateway-<suffix>` credentials (reusing the existing
   `gateway-minio-creds` Secret or generating fresh from
   `/dev/urandom`), writes them back as the canonical `minio.dhall`
   fragment Secret, and applies a one-shot Job in the `minio`
   namespace (using the cluster MinIO root Secret) that creates the
   `prodbox-state` bucket, creates/updates the `prodbox-gateway-<suffix>`
   user, creates/attaches the `prodbox-gateway-policy` IAM policy
   (`gatewayMinioPolicyJson`) granting only `s3:GetObject`/`s3:PutObject`
   on `prodbox-state/*` and `s3:ListBucket` on `prodbox-state`. This replaces the
   transitional MinIO-root credential path. The
   raw Pulumi checkpoint layout remains Sprint `7.14`. The remaining
   gate is the live exercise (deliverable 6).
3. **Gateway pod consumes `gateway-minio-creds`** (Done May 23, 2026):
   `charts/gateway/templates/deployments.yaml` now wires the
   `MINIO_ACCESS_KEY_ID` / `MINIO_SECRET_ACCESS_KEY` env vars from the
   chart-side `gateway-minio-creds` Secret via explicit `valueFrom:
   secretKeyRef:` entries (chosen over `envFrom: secretRef:` so the
   daemon doesn't accidentally receive unrelated keys if the Secret
   gains extra fields later). The daemon ignores the env vars today;
   they wire in when `Prodbox.Secret.MasterSeed` lands.
4. **Gateway daemon endpoint bodies**: replace the structured 503 stubs
   in `Prodbox.Gateway.Daemon::handleRestClient` with the live
   handlers that compose `Prodbox.Secret.MasterSeed.ensureMasterSeed`
   with `Prodbox.Secret.Derive.derive` (and the per-context inventory
   table from doctrine §6 for `ensure-namespace`). Response shapes are
   already pinned by `Prodbox.Secret.Wire`. The handler also needs
   a startup-time `MinioMasterSeedConfig` resolver. **Re-scoped May 24,
   2026 under the pure-Dhall config doctrine
   ([config_doctrine.md](../documents/engineering/config_doctrine.md))**:
   the daemon resolves `MinioMasterSeedConfig` from its parsed Dhall
   config (the `minio` block carries the endpoint URL; the credentials
   come from a Dhall import at `/etc/gateway/secrets/minio.dhall` mounted
   from a sibling k8s Secret per Sprint 2.22). No `MINIO_*` env var is
   read on the supported path. A `DaemonEnv` field caches the resolved
   `MasterSeed` between requests so each `/v1/secret/derive` call is one
   HMAC, not one MinIO round-trip.
5. **Reconcile/delete wiring (Done May 24, 2026 later session)**: the
   chart-side NodePort Service already exists (landed May 23, 2026),
   and the symmetric `runHostFirewallGatewayUnrestrict :: Int -> IO
   ExitCode` helper + operator-facing
   `prodbox host firewall gateway-unrestrict --port PORT` subcommand
   landed May 23, 2026. New `defaultGatewayNodePort = 30443` constant
   and new `runHostFirewallGatewayRestrictOptional` (treats absent
   iptables as success-with-reason — the post-deploy hook is
   defense-in-depth, not the primary contract). The
   `prodbox charts deploy gateway --substrate home-local` apply path
   chains `runHostFirewallGatewayRestrictOptional defaultGatewayNodePort`
   after successful chart deploy via the new
   `applyChartDeployWithPostHook` wrapper in `src/Prodbox/CLI/Charts.hs`;
   the matching `prodbox charts delete gateway --substrate home-local`
   chains `runHostFirewallGatewayUnrestrict defaultGatewayNodePort` via
   `applyChartDeleteWithPostHook`. The cleanup is also chained as a
   safety net into `runNativeDelete` (the `rke2 delete --yes` body) and
   the cascade's step 4 uninstall block in
   `runNativeDeleteCascade`, so a wipe-and-rebuild cycle removes the
   rule even when the gateway chart was already gone. Validation:
   `prodbox dev check` exit 0; `prodbox test unit` 543/543;
   `prodbox test integration cli` 28/28.
6. **Live regression on this host** per the verification block in the
   approved plan Part 3 step 2. **Attempted May 24, 2026 (later
   session)**: `./.build/prodbox test all` (home substrate) ran for
   ~80 minutes; Phase 1+2 reconcile completed cleanly and the
   per-validation chart cleanups ran through the new
   `applyChartDeleteWithPostHook` arm. The aggregate then timed out at
   `helm upgrade --install gateway` after 30 min (`--atomic` rolled
   the release back); the three gateway pods reached `STATUS=Error`
   with 10 restarts each. Root cause: `acquireInitialMasterSeed`
   resolved the MinIO endpoint as `127.0.0.1:9000`, the Pod's own
   loopback, so `aws s3api` against the master-seed object couldn't
   reach MinIO. **May 24, 2026 still-later session — endpoint
   threading + bucket bootstrap landed**: (a) new
   `minio_endpoint_url :: Maybe Text` sibling field on
   `DaemonBootDhall` plus matching `daemonMinioEndpointUrl :: Maybe
   String` on `DaemonConfig`; (b) new
   `Prodbox.Secret.MasterSeed.minioMasterSeedConfigFromUrl` that
   accepts a full endpoint URL string, and `acquireInitialMasterSeed`
   now prefers `daemonMinioEndpointUrl` over the `localPort`
   fallback; (c) `charts/gateway/templates/configmap-config.yaml`
   renders `boot.minio_endpoint_url = Some "{{ .Values.minio.endpointUrl }}"`
   with a default of `http://minio.prodbox.svc.cluster.local:9000`
   in `values.yaml`; (d) new reconcile step `ensureGatewayMinioBucket`
   (in `src/Prodbox/CLI/Rke2.hs`) deploys a one-shot Job in the
   `minio` namespace that runs `mc mb --ignore-existing local/prodbox`
   using the cluster MinIO root Secret as envFrom, mirroring the
   existing harbor-bucket-init shape; (e) transitional credential
   sourcing — `charts/gateway/templates/secret-minio-creds.yaml` now
   resolves MinIO root credentials via a cross-namespace Helm
   `lookup "v1" "Secret" "prodbox" "minio"` so the gateway daemon
   authenticates as root until the dedicated `prodbox-gateway` user
   + IAM policy land in a follow-up. Validation: `prodbox dev check`
   exit 0; `prodbox test unit` 543/543; `prodbox test integration cli`
   28/28; `prodbox test integration env` 28/28;
   `prodbox-daemon-lifecycle` 14/14. The live RKE2 reconcile + gateway
   chart deploy + master-seed acquisition end-to-end exercise remains
   pending; on success the master seed materializes at
   `prodbox/master-seed` and `curl http://127.0.0.1:30443/v1/secret/derive?context=patroni:keycloak:keycloak:app`
   returns a deterministic base64 value. The dedicated
   `prodbox-gateway` IAM user + scoped policy (replacing the
   transitional MinIO-root path) landed May 25, 2026 in
   `ensureGatewayMinioBootstrap` (deliverable 2 above).

   **2026-05-29 — master-seed 403 root cause diagnosed live + fixed.**
   A live `prodbox test all` revealed the long-standing master-seed
   `403 Forbidden` was a **multi-writer credential divergence**, not a
   policy-grant issue: the `gateway-minio-creds` Secret was being
   regenerated by `charts/gateway/templates/secret-minio-creds.yaml`'s
   `lookup` + `randAlphaNum` fallback every time the suite bootstrap
   ran `charts delete gateway` (helm deleted the chart-managed Secret)
   followed by `charts deploy gateway` (lookup found nothing →
   `randAlphaNum` generated a fresh `prodbox-gateway-<suffix>`). That
   fresh user existed in the Secret (and the daemon mounted it) but
   was never registered in MinIO — `ensureGatewayMinioBootstrap` had
   created a different user in MinIO from its own resolution, so the
   daemon authenticated as a non-existent user (`InvalidAccessKeyId`)
   and every HEAD/GET on `prodbox/master-seed` 403'd. Confirmed live:
   the Secret held `prodbox-gateway-vklzldc6`; MinIO held two other
   `prodbox-gateway-*` users from the two reconcile bootstrap Job
   runs; none matched, and `prodbox-gateway-vklzldc6` returned
   `InvalidAccessKeyId` against MinIO admin.

   **Fix landed 2026-05-29.** `charts/gateway/templates/secret-minio-creds.yaml`
   now strictly consumes the reconcile-written Secret (the
   `randAlphaNum` fallback is removed; if `lookup` finds no existing
   Secret the template renders empty credentials, and the daemon
   takes the documented structured 503 master-seed-unavailable path
   per `secret_derivation_doctrine.md` §8). The Secret also carries
   the `helm.sh/resource-policy: keep` annotation so `helm uninstall`
   (i.e. `prodbox charts delete gateway`) **does not** delete it —
   the reconcile-created Secret persists across `charts delete
   gateway` + `charts deploy gateway` cycles, so the daemon's
   credentials always match a user that `ensureGatewayMinioBootstrap`
   registered in MinIO. Validated on the code-owned surface:
   `prodbox dev check` exit 0; `prodbox test unit` 606/606;
   `prodbox test integration cli` 30/30; `prodbox test integration
   env` 30/30; the smoke-install `helm template
   charts/gateway` renders the Secret with empty credentials and the
   keep annotation as specified.

   The **live closure gate** (a `prodbox test all` whose gateway
   pods log `master_seed_ready`, materialize
   `prodbox/master-seed` in MinIO, and return a deterministic
   base64 value from `curl
   http://127.0.0.1:30443/v1/secret/derive?context=patroni:keycloak:keycloak:app`,
   stable across a `delete + reconcile` cycle) is the sole
   remaining Sprint 2.19 deliverable. Now that the root cause is
   fixed, this gate is expected to pass on the next harness-driven
   run.

These deliverables are tightly coupled (the daemon needs the MinIO
client; the chart needs the daemon image; the live exercise needs the
chart) and benefit from being implemented as one connected push in a
dedicated session. The chart-platform integration (Sprint 3.13) blocks
on this sprint's full closure.

**2026-05-30 — live closure (sprint Done).** `prodbox test all` run #6
on the home substrate exercised the full secret-derivation path
end-to-end and confirmed the multi-writer credential divergence is
gone. The final 3-part fix:

1. **Chart no longer competes as a writer.**
   `charts/gateway/templates/secret-minio-creds.yaml` was **removed
   entirely**. The chart no longer renders the
   `gateway-minio-creds` Secret at all; the
   `lookup` + `randAlphaNum` fallback path that produced fresh
   `prodbox-gateway-<suffix>` users on every `charts deploy gateway`
   is gone, eliminating the multi-writer race at its source.
2. **Reconcile-written Secret survives `helm uninstall`.**
   `src/Prodbox/CLI/Rke2.hs::writeGatewayMinioCredsSecret` now stamps
   `helm.sh/resource-policy: keep` on the Secret it writes (via a
   `kubectl annotate --overwrite` step), so a subsequent
   `prodbox charts delete gateway` (= `helm uninstall`) does **not**
   delete it. The reconcile-created Secret persists across
   `delete + redeploy` cycles, so the daemon's credentials always
   match a user that `ensureGatewayMinioBootstrap` registered in
   MinIO.
3. **Bootstrap runs around every gateway `delete + deploy`.**
   `src/Prodbox/TestRunner.hs` now invokes
   `Prodbox.CLI.Rke2.ensureGatewayMinioBootstrap` **between**
   `charts delete gateway` and `charts deploy gateway` in **both**
   `supportedRuntimeBootstrapActions` and
   `supportedRuntimePostflightActions` so the Secret + the matching
   MinIO user are guaranteed in sync going into the chart deploy.
   `ensureGatewayMinioBootstrap` was newly exported from
   `Prodbox.CLI.Rke2` for this call site.

Verification (run #6, 2026-05-30, home substrate): the gateway daemon
logged `master_seed_ready` with
`field_endpoint: http://minio.prodbox.svc.cluster.local:9000` and
`field_source: minio:prodbox/master-seed`. The `gateway-minio-creds`
Secret held `prodbox-gateway-43b04842`, matching the MinIO user
registered by `ensureGatewayMinioBootstrap`. The three gateway pods
reached Running 1/1 with 0 restarts. The `gateway-daemon` validation
body exited Success; `gateway-pods` and `gateway-partition`
validation bodies exited Success. The aggregate `prodbox test all`
roll-up: 16/17 green (only `keycloak-invite` failed, a known
Sprint 8.5 operator-driven gap).

### Remaining Work

- None. The historical sprint closed in 2026-05; Sprint `3.19` subsequently removed the entire
  master-seed/RPC design and current negative-space tests keep it absent.

## Sprint 2.20: Daemon Dhall Settings Module [✅ Done]

**Status**: Done (May 24, 2026; the later Sprint `2.24` flag cleanup is also complete).
**Implementation**: new `src/Prodbox/Gateway/Settings.hs`, `src/Prodbox/Gateway/Types.hs`
(remove `parseDaemonConfig` JSON path), `src/Prodbox/Gateway/Daemon.hs` (remove the
JSON-flat-compat schema branch), `src/Prodbox/Gateway.hs` (remove `PRODBOX_*` env-var
reads), `src/Prodbox/CLI/Spec.hs` and `src/Prodbox/CLI/Parser.hs` (remove `--log-level`,
`--port`, `--node-id`, `--foreground` daemon flags), the gateway Dhall decoder records,
`test/unit/Main.hs` (extend with Dhall round-trip tests)
**Independent Validation**: Dhall decode/error tables, generated `gateway.dhall` fixtures, parser
tests, and the loopback daemon-lifecycle stanza validate the config path without a later phase.
**Docs to update**: `documents/engineering/distributed_gateway_architecture.md`,
`documents/engineering/cli_command_surface.md`,
`DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md`

### Objective

Implement the host-CLI Dhall decoder pattern (Sprint 1.2) for the in-cluster gateway
daemon, replacing the JSON config parser. The daemon's `BootConfig` and `LiveConfig`
record types come from a Dhall expression at `--config <path>`, decoded in-process via
`Dhall.inputFile auto`. See
[config_doctrine.md §4](../documents/engineering/config_doctrine.md#4-decoding) for the
authoritative decoder contract.

### Deliverables

- New `src/Prodbox/Gateway/Settings.hs` exposing `loadDaemonConfig :: FilePath -> IO
  DaemonConfig` built on `Dhall.inputFile auto`. The module mirrors `src/Prodbox/Settings.hs`
  in structure.
- Removal of `Prodbox.Gateway.Types.parseDaemonConfig` and the structured-vs-flat JSON
  branch in `Prodbox.Gateway.Daemon`. The `DaemonConfig`, `BootConfig`, and `LiveConfig`
  record types stay; only the parser changes.
- Removal of `PRODBOX_LOG_LEVEL`, `PRODBOX_CONFIG_PATH`, `PRODBOX_PORT` env-var reads in
  `src/Prodbox/Gateway.hs`. The `prodbox gateway start` / `prodbox workload start` parser
  spec accepts only `--config <path>`.
- `Prodbox.Gateway.Settings` owns the typed Dhall decoder records used by chart-rendered gateway
  config; no unresolved schema-file choice remains.
- 20+ unit tests covering: happy-path Dhall decode, malformed-Dhall surface,
  schemaVersion-mismatch handling, BootConfig-vs-LiveConfig classifier purity.

### Validation

1. `prodbox dev check` exit 0.
2. `prodbox test unit` adds Dhall round-trip coverage for the new decoder.
3. `prodbox test integration cli` continues to pass (28/28).
4. Live exercise: `prodbox gateway start --config <path-to-test-dhall>` decodes a
   minimal Dhall fixture and serves `/healthz` 200.

### Remaining Work

- None.

## Sprint 2.21: File-Watch Reload Trigger and Auto-Restart on BootConfig Change [✅ Done]

**Status**: Done (May 24, 2026; live file-watch closure 2026-06-02). Sprint `2.23` closes
the drain-completion cancellation residual found during that live exercise.
**Implementation**: `src/Prodbox/Gateway/Daemon.hs` (remove SIGHUP handler, add
file-watch worker, implement drain-and-exit on BootConfig change), `prodbox.cabal` (add
`fsnotify` or equivalent dep), `src/Prodbox/CheckCode.hs` (remove `forbidFsnotify` /
`forbidInotify` / forbid-mtime lint rules), `.hlint.yaml` (remove matching marker set),
`test/daemon-lifecycle/Main.hs` (extend with file-watch reload + drain-and-exit goldens)
**Independent Validation**: pure boot/live change classification, daemon-lifecycle file-watch and
SIGTERM/drain tests, plus the recorded home ConfigMap exercise validate reload and restart behavior
without a later phase.
**Docs to update**: `documents/engineering/distributed_gateway_architecture.md`,
`documents/engineering/unit_testing_policy.md`,
`DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md`

### Objective

Replace the SIGHUP-driven reload trigger with a file-watch trigger on the daemon's
`--config` Dhall path. Implement the BootConfig-change drain-and-exit path so the
kubelet restarts the Pod with the new config. See
[config_doctrine.md §7 and §8](../documents/engineering/config_doctrine.md#7-file-watch-reload-trigger).

### Deliverables

- New file-watch worker in `Prodbox.Gateway.Daemon` that subscribes to events on the
  parent directory of the `--config` path (so the kubelet's atomic `..data` symlink
  swap fires the event). The worker feeds the same `TBQueue ()` reload queue the
  current implementation already drains.
- Removal of the `installHandler sigHUP` call and the SIGHUP-handler scaffolding.
  SIGHUP becomes an ordinary terminate signal handled by the existing `drain + exit`
  path.
- Implementation of the drain-and-exit branch on BootConfig change: when the re-decoded
  Dhall differs from the running config on any BootConfig field, the worker logs
  `config_reload_boot_change_detected`, calls the existing drain machinery
  (`liveDrainDeadlineSeconds` default 30s), and exits with `ExitSuccess`. The kubelet
  restarts the Pod against the new Dhall.
- Removal of the `forbidFsnotify`, `forbidInotify`, and forbid-mtime-polling lint rules
  in `src/Prodbox/CheckCode.hs` and the matching marker set in `.hlint.yaml`.
- New `test/daemon-lifecycle/Main.hs` cases: file-watch picks up a write, LiveConfig
  diff hot-reloads, BootConfig diff drains and exits with `ExitSuccess`.
- Extension of the `prodbox-daemon-lifecycle` golden set for the new event labels.

### Validation

1. `prodbox dev check` exit 0 (proves the lint-rule removal is symmetric with the
   doctrine update).
2. `prodbox test unit` exit 0.
3. `prodbox test integration cli` exit 0.
4. `cabal test prodbox-daemon-lifecycle` exit 0 (new file-watch goldens pass).
5. Live exercise on this host: `prodbox rke2 reconcile` brings up the gateway daemon
   with a mounted Dhall config; editing the ConfigMap changes the rendered file; the
   daemon picks up the change within ~kubelet sync period; LiveConfig-only changes
   reload in-process, BootConfig changes drain-and-exit and the kubelet restarts the
   Pod.

### Remaining Work

- None. The implementation uses `fsnotify`; the home file-watch exercise landed on 2026-06-02, and
  Sprint `2.23` closes the separate cancellation residual it exposed.

## Sprint 2.22: Chart-Side Dhall ConfigMap and Credential Migration (Historical) [✅ Done]

**Status**: Done (May 24, 2026 historical migration; its Secret-mounted credential fragments were
subsequently superseded and removed by Vault Kubernetes auth in Sprints `3.18`/`3.19`).
**Implementation**: historical Dhall render/mount work in `charts/gateway/` and
`src/Prodbox/Gateway/Settings.hs`; current replacement in `src/Prodbox/Settings.hs`,
`src/Prodbox/Vault/Reconcile.hs`, `src/Prodbox/Secret/VaultInventory.hs`, and `charts/gateway/`
**Independent Validation**: historical chart-render and home gateway/DNS tests proved the migration
at closure; current chart/unit negative-space tests prove ambient credential env vars and
Secret-mounted Dhall fragments remain absent while typed Vault references decode locally.
**Docs to update**: `documents/engineering/helm_chart_platform_doctrine.md`,
`documents/engineering/secret_derivation_doctrine.md`,
`DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md`

> **Superseded architecture record.** The objective, deliverables, and validation below describe
> the intermediate May 2026 Dhall-fragment Secret design. The supported gateway now resolves typed
> `SecretRef.Vault` values through Vault Kubernetes auth; it does not mount AWS/MinIO credential
> fragments or inherit ambient AWS authentication.

### Objective

The historical objective replaced JSON-rendered gateway config and ambient credential environment
variables with Dhall-rendered config plus Secret-mounted Dhall fragments. Vault Kubernetes auth
later superseded the credential half of that migration; the bullets below are historical evidence.

### Deliverables

The following credential-fragment deliverables are historical; the ConfigMap/Dhall config boundary
remains, while current secret values resolve from Vault:

- Rewrite `charts/gateway/templates/configmap-config.yaml` to render Dhall content at
  `/etc/gateway/config.dhall`. **[Superseded by Sprint 2.21:** the ConfigMap is now a directory
  mount at `/etc/gateway/config`, so the daemon's `--config` is `/etc/gateway/config/config.dhall`
  — see [config_doctrine.md §6](../documents/engineering/config_doctrine.md#6-cluster-mount-contract).**]**
  The Dhall expression imports
  `/etc/gateway/orders.dhall`, `/etc/gateway/secrets/aws.dhall`, and
  `/etc/gateway/secrets/minio.dhall`.
- Rewrite `charts/gateway/templates/configmap-orders.yaml` to render Dhall content at
  `/etc/gateway/orders.dhall`.
- New `gateway-secrets-aws` Secret containing a Dhall fragment for AWS credentials,
  mounted at `/etc/gateway/secrets/aws.dhall`. Replaces the `gateway-aws-credentials`
  env-var-sourced Secret.
- New `gateway-secrets-minio` Secret containing a Dhall fragment for MinIO credentials,
  mounted at `/etc/gateway/secrets/minio.dhall`. Replaces the env-var path through
  `gateway-minio-creds`.
- Removal of `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN`,
  `MINIO_ACCESS_KEY_ID`, `MINIO_SECRET_ACCESS_KEY`, `GATEWAY_NODE_ID` env vars from
  `charts/gateway/templates/deployments.yaml`. The daemon Pod's only environment is
  k8s runtime metadata the binary does not read for config.
- The `gateway-minio-creds` Secret name may be reused for the new Dhall-content Secret,
  but the key shape changes (single `minio.dhall` key instead of two env-var-shaped
  keys).

### Validation

1. `prodbox dev check` exit 0.
2. `helm template gateway charts/gateway` renders cleanly.
3. `prodbox dev lint chart` exit 0 (chart structural invariants stay green).
4. Live exercise: `prodbox rke2 reconcile` brings up the gateway daemon with the new
   chart layout; the daemon reads `/etc/gateway/config.dhall` (Sprint 2.21 moved this to the
   directory mount `/etc/gateway/config`, i.e. `/etc/gateway/config/config.dhall`), imports the credential
   Secrets, connects to MinIO, and serves `/healthz` 200.

### Remaining Work

- None. The intermediate chart migration was live-proven on 2026-06-01 and the later Vault-native
  replacement is complete; no Secret-mounted credential fragment remains current work.

## Sprint 2.23: Drain-Cancellation Propagation [✅ Done]

**Status**: Done
**Implementation**: `src/Prodbox/Gateway/Daemon.hs`, `test/daemon-lifecycle/Main.hs`,
`DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md`
**Independent Validation**: the real daemon-lifecycle process tests prove first-SIGTERM graceful
exit and second-SIGTERM prompt force-drain; the pure control-flow audit proves both normal and
exceptional worker completion return when readiness is `Draining`, with no cluster or later phase.
**Docs to update**: `documents/engineering/distributed_gateway_architecture.md`,
`documents/engineering/unit_testing_policy.md`, `DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md`

### Objective

Ensure the drain coordinator's structured cancellation of `dnsWriteLoop` and its sibling workers is
classified as intentional shutdown rather than retried or rethrown as a fatal worker failure.

### Deliverables

- `serveGatewayDaemon` races `drainCoordinator` against `daemonWorkers`, so drain completion cancels
  the worker tree through structured concurrency.
- `runWorkerWithRetry` observes readiness before classifying either a normal worker return or an
  exception; `Draining` returns immediately in both cases, while non-draining asynchronous
  cancellation remains fatal.
- The first-/second-SIGTERM daemon-lifecycle cases pin graceful and forced drain completion.
- The stale deferred-follow-up references are closed and the residual is recorded under
  `Completed` in the cleanup ledger.

### Validation

1. `cabal test --builddir=.build prodbox-daemon-lifecycle --test-options=--hide-successes`
2. Source correspondence: `serveGatewayDaemon` owns the drain/worker race and
   `runWorkerWithRetry` handles `Draining` before retry/fatal classification.
3. `prodbox dev check`

### Remaining Work

- None.

## Sprint 2.24: Delete Daemon `--log-level` / `--port` / `--foreground` Override Flags [✅ Done]

**Status**: Done (2026-06-09). The three runtime-override flags + `foregroundParser` were removed
from both `daemonLaunchOptionsParser` and `workloadOptionsParser`, the matching
`DaemonLaunchOptions`/`WorkloadOptions` fields and the threading through `Gateway.hs`/`Daemon.hs`
(`runGatewayDaemon :: Maybe FilePath -> DaemonConfig -> IO ExitCode`) dropped; `gateway start` =
`--config` + `--dry-run` + `--plan-file`, `workload start` = `--config`. The daemon now sources
`log_level` from the mounted Dhall (`live.log_level`, default `info`) and the REST port from Orders
(`peerRestPort`); the daemon-lifecycle harness injects the port via the generated Orders Dhall
instead of `--port`. The generated §2/§3 matrix + CLI goldens were regenerated and both ledger rows
moved to Completed. The `Workload.hs` `PRODBOX_*` env ladder is intentionally retained (Sprint
3.15). Validation green: `check-code` 0, `test unit` 0, `integration cli` 0,
`prodbox-daemon-lifecycle` 13/13, `lint docs` 0, `docs check` 0.
**Implementation**: `src/Prodbox/CLI/Spec.hs`, `src/Prodbox/CLI/Parser.hs`,
`src/Prodbox/CLI/Command.hs`, `src/Prodbox/Gateway.hs`, `src/Prodbox/Workload.hs`,
`test/daemon-lifecycle/Main.hs`, `DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md` (recommended)
**Independent Validation**: parser rejection/roundtrip tests, generated help/goldens, and the real
daemon-lifecycle fixture prove the override flags and their threading are absent without a later
phase.
**Docs to update**: `documents/engineering/cli_command_surface.md`,
`documents/engineering/config_doctrine.md`,
`documents/engineering/distributed_gateway_architecture.md`,
`DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md`

### Objective

Land the deferred Sprint 2.20 ledger removal: delete the daemon-launching commands'
`--log-level`, `--port`, and `--foreground` override flags and the threading that carries them
through `BootConfig` resolution, so `prodbox gateway start` and `prodbox workload start` take
exactly one startup-time CLI knob — `--config <path>` — per
[config_doctrine.md §2 and §10](../documents/engineering/config_doctrine.md#2-single-dhall-surface-per-binary-instance).
Sprint 2.20 closed its Dhall-decoder surface but left these flags in place because the
daemon-lifecycle test harness used `--port` for port allocation and the operator
`gateway status` / `config-gen` commands still threaded `--log-level`; this sprint removes the
flags and rewires those call sites onto the Dhall surface.

### Deliverables

- Remove the `--log-level`, `--port`, and `--foreground` flags from the `prodbox gateway start`
  and `prodbox workload start` `CommandSpec` entries in `src/Prodbox/CLI/Spec.hs` and the
  matching parser arms in `src/Prodbox/CLI/Parser.hs` / constructors in
  `src/Prodbox/CLI/Command.hs`. `--config <path>` becomes the sole startup-time knob; the daemon
  refuses to start on missing or unparseable config.
- Remove the threading that lets those flags override `BootConfig` defaults: log level, listen
  port, and foreground/daemonize disposition all come from the decoded Dhall config. The
  CLI-flag > env-var > Dhall-default > built-in-default precedence ladder named in the closed
  Sprint 2.15 deliverables collapses to Dhall-default > built-in-default (no CLI or env-var tier
  survives on the supported path).
- Rewire the `prodbox-daemon-lifecycle` stanza (Sprint 2.14) so its port allocation flows through
  a generated Dhall fixture's `boot` port field rather than a `--port` flag; the operator
  `gateway status` / `config-gen` commands take their log level from the same decoded config.
- Move the `--log-level` / `--port` / `--foreground` flag-shape entry from `Pending Removal` to
  `Completed` in [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md) once the
  flags are gone.
- Regression guard: the `prodbox-unit` parser-shape test pins the reduced `DaemonLaunchOptions`
  record (config + plan-options only), and the §2/§3 matrix is generated from the `CommandSpec`
  registry — reintroducing any of the three flags changes the record arity (test compile-break)
  and the generated matrix (docs-check drift), so reintroduction fails a gate. A dedicated
  string-scan lint was judged unnecessary given the parser is generated-from-spec and unit-tested.

### Validation

1. `prodbox dev check` exit 0.
2. `prodbox test unit` exit 0 (parser-shape coverage proves the three flags are absent on the
   daemon-launching commands).
3. `prodbox test integration cli` exit 0.
4. `cabal test prodbox-daemon-lifecycle` exit 0 (the stanza allocates its port through the Dhall
   fixture rather than a `--port` flag).
5. `prodbox gateway start --config <path>` and `prodbox workload start --config <path>` accept no
   other startup-time flag and refuse to start on missing or unparseable config.

### Remaining Work

- None. Flags and threading are removed; the daemon sources port/log-level from Dhall/Orders, and
  tests, generated artifacts, and ledger history record the closure.

## Sprint 2.25: Gateway Runtime Robustness and Topology-Honest Fault Model [✅ Done]

**Status**: Done (2026-06-09; the home gateway validations were subsequently live-proven on
2026-06-26). At closure, all six deliverables landed: per-connection
`withAsync` + bounded `receiveAllWithin` read timeout (from `LiveConfig`, shutdown-aware) on both
listeners; `/v1/state` splits `peer_transport` into `peer_inbound_health` + `peer_outbound_health`
(`markPeerOk` no longer stamps the inbound field); one canonical base64url event-key encoding
(`deriveBase64Url`; the `deriveHex` divergence, the Sprint-2.21 chunk-48 reload overlay, and the
false "agree by construction" comment removed); a typed `DeriveContext` with a `decodeDeriveContext`
inverse + a `decode . encode == id` property (de-risks GET `/v1/secret/derive`, audit C82);
restart-based Orders promotion (`eventTypeOrdersPromoted`/`extractOrdersVersionFromEvent`/
`updateOrdersAdvert` deleted, the refuse-to-reclaim-while-behind gate kept); and the
`markEventProcessed` IS-NULL first-write-wins guard in `Daemon/Events.hs`. Sprint `2.31` subsequently
replaced the then-current peer log with bounded semantic anti-entropy. The D4 + topology-honest
doctrine reframes were verified consistent (Sprint 0.9).
Validation green: `check-code` 0, `test unit` 760, `integration cli` 35, `prodbox-daemon-lifecycle`
14/14, `lint docs` 0, `docs check` 0; the later home live run closed the infrastructure axis.
**Historical behavior note (superseded by Sprint `3.19`):** at Sprint `2.25` closure, retiring the
chunk-48 overlay made a first-install empty `event_keys` ConfigMap classify as a boot change and
drain-and-exit. Vault-native event-key resolution removed that intermediate ConfigMap derivation
path; this note is retained only as closure evidence.
**Implementation**: `src/Prodbox/Gateway/Daemon.hs`, `src/Prodbox/Gateway/Types.hs`,
`src/Prodbox/Gateway/Peer.hs`, `src/Prodbox/Daemon/Events.hs`, `test/unit/Main.hs`,
`test/daemon-lifecycle/Main.hs` (recommended)
**Independent Validation**: pure encoding/Orders/idempotency tests, real loopback connection and
health-split tests, and the native partition fixture prove this runtime/fault-model surface without
a later phase; the home live validations are also proven.
**Docs to update**: `documents/engineering/distributed_gateway_architecture.md`,
`documents/engineering/config_doctrine.md`,
`documents/engineering/secret_derivation_doctrine.md`,
`documents/engineering/streaming_doctrine.md`,
`documents/engineering/tla_modelling_assumptions.md`

### Objective

Harden the gateway runtime's connection handling, peer-health accounting, event-key encoding, and
Orders-promotion model, and reframe the gateway fault-model doctrine so it is topology-honest: the
home substrate runs three logical ranked peers on one physical host under shared fate. Logical
peer/network partitions remain exercisable, while independent physical-host failure tolerance is
an AWS / future-multi-host capability. This sprint also enacts doctrine change **D4** — Orders promotion is restart-based, not
an in-process version advance — across
[distributed_gateway_architecture.md §7.5](../documents/engineering/distributed_gateway_architecture.md)
and [tla_modelling_assumptions.md](../documents/engineering/tla_modelling_assumptions.md), per
[config_doctrine.md §8 step 4](../documents/engineering/config_doctrine.md#8-boot-vs-live-split-and-the-restart-contract),
which already defines the restart contract.

### Deliverables

The connection, health-split, restart-based Orders, durable-event idempotency, and topology
deliverables remain current. The derive-context RPC and old peer-log references below are historical:
Sprint `3.19` removed the derivation RPC, and Sprint `2.31` replaced the log transport.

- Wrap each inbound connection on both the REST and peer-events listeners in its own `withAsync`
  with a bounded read timeout, so a slow or stuck peer cannot wedge the accept loop; the timeout
  is sourced from `LiveConfig` and the cancellation is intentional-shutdown-aware (it does not
  classify as a `Fatal` worker error during `Draining`).
- Split inbound-vs-outbound peer health: `/v1/state` reports inbound delivery health (last
  accepted event age per peer) separately from outbound dial health (connect state, last dial
  error per peer), so a one-directional partition is observable rather than collapsed into a
  single `peer_transport` health value.
- Collapse the event-key handling onto one typed encoding: define a single canonical event-key
  encoding (the base64url surface already produced by the chart-rendered `event_keys`) and remove
  the divergent in-memory `deriveHex` re-derivation path so the boot-change classifier and the
  HMAC signing/verification path agree on one representation. The Sprint 2.21 chunk-48 workaround
  (reapply the in-memory derivation before `daemonBootFieldsChanged` compares) is retired in
  favor of the single encoding.
- Add a derive-context encode/decode round-trip: the typed context constructors in
  `Prodbox.Secret.Derive` (and any event-key context) gain an inverse decoder, with a property
  test asserting `decode . encode == id` so the wire shape is provably stable.
- **Restart-based Orders promotion (doctrine D4)**: rewrite
  [distributed_gateway_architecture.md §7.5](../documents/engineering/distributed_gateway_architecture.md)
  and [tla_modelling_assumptions.md](../documents/engineering/tla_modelling_assumptions.md) so a
  new Orders document is adopted by restarting the daemon against the new config (per
  [config_doctrine.md §8](../documents/engineering/config_doctrine.md#8-boot-vs-live-split-and-the-restart-contract)),
  not by advancing `stateOrdersVersionUtc` in-process. `stateOrdersVersionUtc` never advances at
  runtime; the dead in-process `orders_promoted` promotion machinery is deleted. The
  refuse-to-reclaim-while-behind gate (`stateLatestObservedOrdersVersion > stateOrdersVersionUtc`
  blocks ownership claims) is **kept** — a daemon that observes a newer Orders version refuses to
  claim until it is restarted against that version.
- Restore the `markEventProcessed` IS-NULL guard in `src/Prodbox/Daemon/Events.hs` so a
  processed-marker write only fires when `processed_at IS NULL`, preserving the at-least-once
  idempotent-replay contract from
  [streaming_doctrine.md#9-at-least-once-event-processing](../documents/engineering/streaming_doctrine.md#9-at-least-once-event-processing)
  under concurrent processors.
- Topology-honest fault-model reframe in
  [distributed_gateway_architecture.md](../documents/engineering/distributed_gateway_architecture.md)
  and [tla_modelling_assumptions.md](../documents/engineering/tla_modelling_assumptions.md): a
  note recording that the home substrate is a three-logical-peer mesh on one physical host (the
  gateway pods share host fate, so a host failure is not independently tolerated), while logical
  peer/network partitions still exercise the claim/yield, bounded-skew, and refuse-to-reclaim
  gates. Independent-host partition tolerance is the AWS / future-multi-host capability.

### Validation

1. `prodbox dev check` exit 0.
2. `prodbox test unit` exit 0, including the derive-context `decode . encode == id` property test
   and the single-event-key-encoding unit coverage.
3. `cabal test prodbox-daemon-lifecycle` exit 0 (per-connection timeout and inbound/outbound
   health-split assertions).
4. `prodbox test integration gateway-daemon`, `gateway-pods`, and `gateway-partition` exit 0.
5. A unit test proves `markEventProcessed` is a no-op when `processed_at` is already set
   (IS-NULL-guard idempotency).
6. Text-search proof shows the in-process `orders_promoted` promotion machinery is removed and
   `stateOrdersVersionUtc` has no in-process advance site, while the refuse-to-reclaim gate
   remains.

### Remaining Work

- None. The code-owned surface closed 2026-06-09 and the home `gateway-daemon` and `gateway-pods`
  validations were live-proven on 2026-06-26. **Standard-C correction (2026-08-11):** the original
  line included `gateway-partition` in that live proof. It has no live path — it was registered with
  `-> []` prerequisites and ran wholly in process, and since Sprint `5.33` ✅ it is not an
  integration verb at all. Step 4 above therefore names a command that no longer exists for that
  node; the property it covered is pinned in the unit suite. See the note on `gateway-partition` at
  the head of this document, which is the single place this scope is stated for all eight citing
  sprints.

## Sprint 2.26: Cluster Federation Trust Topology and Downstream-Cluster Custody [✅ Done]

**Status**: Done
**Implementation**: `src/Prodbox/Cluster/Federation.hs`, `src/Prodbox/CLI/Command.hs`,
`src/Prodbox/CLI/Spec.hs`, `src/Prodbox/CLI/Rke2.hs`, `src/Prodbox/Gateway/Types.hs`,
`src/Prodbox/Gateway/Settings.hs`, `src/Prodbox/Gateway/Daemon.hs`,
`src/Prodbox/Gateway/Client.hs`, `test/unit/Main.hs`, `test/unit/Parser.hs`,
`test/integration/CliSuite.hs`, `documents/cli/commands.md`, `share/completion/`,
`share/man/man1/`
**Independent Validation**: pure custody/path/redaction tables and fake Vault/kubectl CLI integration
prove registration and gateway read behavior with sealed/unavailable refusal; no live child cluster
or later phase is required for this sprint's owned surface.
**Docs to update**: `documents/engineering/cluster_federation_doctrine.md`,
`documents/engineering/vault_doctrine.md`,
`documents/engineering/config_doctrine.md`,
`documents/engineering/distributed_gateway_architecture.md`

### Objective

Give prodbox the gateway and CLI surface to manage a hierarchy of clusters as a Vault transit-seal
trust tree per
[cluster_federation_doctrine.md](../documents/engineering/cluster_federation_doctrine.md). A root
cluster and zero or more downstream/child clusters form a trust tree: the root cluster's Vault is
Shamir-sealed and unsealed only by the operator, while each child cluster's Vault uses
`seal "transit"` pointed at its parent's Vault and auto-unseals against the parent with no human and
no local unseal keys. The parent custodies each child's init keys (recovery keys plus initial root
token) in its own Vault KV, and a cluster's knowledge of its downstream clusters is secret data
legible only behind an unsealed Vault. This sprint owns the registration and custody surface. The
seal-mode wiring and per-cluster seal custody model have landed in Sprint `3.20`; Sprint `4.32`
now supplies the parent-side live registration writer plus the child `cluster reconcile`
auto-unseal and fail-closed cascade lifecycle interpreter. Sprint `2.26` closes the gateway-owned
read path: the daemon logs in to Vault through its configured Kubernetes auth block, lists children
from the parent-custodied child index, and returns a child bootstrap credential only from the
parent's unsealed Vault KV.

### Deliverables

- A `prodbox cluster federation register <child>` surface (operator-interactive on the root,
  gateway-mediated in-cluster) that records a downstream child cluster's identity, endpoints,
  kubeconfig reference, account id, and Pulumi-stack references as Vault KV objects behind the
  root's unsealed Vault, never as plaintext in `prodbox-config.dhall`, per
  [cluster_federation_doctrine.md](../documents/engineering/cluster_federation_doctrine.md) and
  [config_doctrine.md](../documents/engineering/config_doctrine.md).
- The parent-owns-child-init-keys contract is enacted at child registration: the child's recovery
  keys and initial root token are written to the parent's Vault KV, and the parent's Transit key is
  recorded as the child's unseal authority. A child Vault therefore cannot unseal without a live,
  unsealed parent, per
  [vault_doctrine.md](../documents/engineering/vault_doctrine.md).
- Downstream-cluster metadata is treated as secret: with the parent Vault sealed, no child cluster's
  existence, identity, endpoint, kubeconfig, account id, or Pulumi stack is determinable beyond the
  unencrypted basics (cluster id, this cluster's Vault address, seal mode, and a child's parent
  reference) defined by
  [config_doctrine.md](../documents/engineering/config_doctrine.md).
- Downstream identity is custodied in the parent's Vault KV (`secret/data/clusters/<child-id>/*`
  as the KV v2 API path), never as a Kubernetes Secret or a child-named Kubernetes namespace: any
  in-cluster namespace prodbox derives per child uses an opaque ID, so a Kubernetes ConfigMap/Secret
  dump under a sealed parent Vault reveals no child-cluster name — the same whole-system
  zero-child-info invariant the Model-B object-store enforces for MinIO objects (the parent's
  downstream-cluster references ride the §9 object-store as `DownstreamCluster <id>` logical objects
  under opaque `objects/<hmac>.enc` keys), per
  [vault_doctrine.md §9](../documents/engineering/vault_doctrine.md) and
  [cluster_federation_doctrine.md](../documents/engineering/cluster_federation_doctrine.md). The
  k8s-namespace and log redaction enforcement land in Sprint `4.33`, which this sprint's custody
  surface composes with.
- The gateway exposes a child-listing and child-bootstrap-reference surface so a child cluster can
  fetch the bootstrap reference and transit-seal credential it needs to reach its parent's Vault and
  auto-unseal, with that material provisioned and owned by the parent.
- The federation surface refuses to write or mutate root-cluster federation state without the root
  Vault token, since root federation state governs every downstream cluster, per
  [cluster_federation_doctrine.md](../documents/engineering/cluster_federation_doctrine.md).

### Validation

1. `prodbox dev check` exit 0.
2. `prodbox test unit` exit 0, including coverage that downstream-cluster metadata round-trips as a
   Vault KV object and that the unencrypted basics never carry child-cluster identities.
3. `prodbox cluster federation register <child>` writes the child's init keys and metadata only
   through the parent's unsealed Vault and refuses to run against a sealed parent Vault.
4. A negative test proves a root-cluster federation-state mutation is rejected without the root
   Vault token.
5. Opaque-namespace proof: any per-child Kubernetes namespace prodbox derives is an opaque ID, so a
   ConfigMap/Secret dump under a sealed parent Vault carries no child-cluster name (the whole-system
   zero-child-info invariant; enforced and red-teamed end-to-end by Sprints `4.33` and `5.8`).
6. Operator-driven live validation: registering a child cluster against a running parent cluster and
   confirming the child auto-unseals against the parent's Transit key (requires two live clusters;
   matches the live-gate pattern the substrate sprints use).

### Current State

- The landed foundation covers the pure typed custody contract:
  `Prodbox.Cluster.Federation` owns child metadata/init-key Vault KV JSON framing, parent-owned
  KV path construction, the parent child-index KV object, the bootstrap-credential KV object,
  opaque child namespace/Transit key derivation, root-token write gating, and the plan renderer;
  `prodbox cluster federation register <child>` is wired through the native command registry and
  generated CLI docs/completions/manpages.
- Sprint `4.32` landed the direct parent-side live apply path: it requires a ready parent root
  Vault, child Vault address, and child kubeconfig; writes the child Transit key, scoped policy,
  metadata KV, bootstrap-credential KV, child index KV, and child bootstrap Secret; and leaves the
  token out of command output.
- Sprint `2.26` historically extended the registration payload with parent-custodied endpoint
  inventory, kubeconfig reference, account id, and Pulumi stack references and exposed two Gateway
  federation reads. Sprint `4.50` superseded that transport: both routes, their client functions,
  daemon handlers, and bounded-operation constructors are deleted; current delivery/read-back is
  owned by the Lifecycle Authority and Target Secret Agent.
- The end-to-end opaque Kubernetes namespace/log redaction proof is composed from the Sprint `4.33`
  Haskell-side gate/redaction work and the sealed-state red-team in Sprint `5.8`.

### Remaining Work

- None for Phase `2`. Sprint `2.26`'s historical gateway/CLI custody surface was later superseded
  and removed by Sprint `4.50`; the Haskell redaction work and home sealed-Vault proof landed under
  Sprints `4.33` and `5.8`.

### Current Validation State

- `cabal build --builddir=.build exe:prodbox` passes with
  `src/Prodbox/Cluster/Federation.hs` in the library module set.
- `cabal test --builddir=.build test:prodbox-unit --test-options='-p "cluster federation custody"'`
  passes 9/9 after the child index, bootstrap-credential KV, and downstream-inventory additions.
- `cabal test --builddir=.build test:prodbox-unit --test-options='-p "native gateway helpers"'`
  passes 3/3, including the daemon Vault-auth coordinate decode.
- `cabal test --builddir=.build test:prodbox-unit --test-options='-p "parser"'` passes 258/258,
  including the updated generated command examples for `cluster federation register`.
- Historical Sprint `2.26` validation proved the then-current read transport. The current Sprint
  `4.50` negative integration fixture starts the built daemon and requires both removed paths to
  return `404`.
- `cabal test --builddir=.build test:prodbox-integration --test-options='-p "Sprint 4.32"'`
  passes 1/1 after the registration writer records metadata, bootstrap credential, and child-index
  KV objects against fake Vault and fake kubectl without printing the child token.
- `./.build/prodbox test unit` passes 924/924 after accepting the updated generated CLI
  registry/help goldens for the new federation-register inventory flags.
- The historical aggregate passed 38/38; current aggregate evidence is recorded under Sprint
  `4.50` after the superseding negative-route fixture validates.
- `./.build/prodbox dev docs check`, `./.build/prodbox dev lint docs`, and `git diff --check`
  all exit 0 after the plan/docs closure update.
- `./.build/prodbox dev check` exits 0 as the canonical local quality gate.

## Sprint 2.27: Gateway Gossip + Orders to Canonical CBOR [✅ Done]

**Status**: Done (2026-07-02)
**Implementation**: `src/Prodbox/Gateway/Peer.hs`, `src/Prodbox/Gateway/State.hs`,
`src/Prodbox/Gateway/Types.hs`, `prodbox.cabal`
**Live-proof**: pending
**Independent Validation**: unit + CLI/env integration on the home/local substrate — `Orders`,
signed assertion, cursor/delta, and repair round trips plus `prodbox test integration cli`/`env`
prove the CBOR wire codec on the gateway's owned surface with no dependency on any later phase.
**Docs to update**: `documents/engineering/pulsar_messaging_doctrine.md`, `documents/engineering/distributed_gateway_architecture.md`, `documents/engineering/code_quality.md`

### Objective

Keep the gateway anti-entropy protocol and the `Orders` serialized envelope on canonical CBOR so
the mesh transport shares the one canonical binary codec that
[pulsar_messaging_doctrine.md](../documents/engineering/pulsar_messaging_doctrine.md) makes
project-wide. Sprint `2.27` performed the JSON-to-CBOR migration; Sprint `2.31` retains that codec
while replacing the historical event-batch shape with bounded cursor/delta/repair frames. This supersedes the residual non-CBOR wire language in
[distributed_gateway_architecture.md](../documents/engineering/distributed_gateway_architecture.md)
and renames the `Lint.Proto` stanza to `Lint.Cbor` per
[code_quality.md](../documents/engineering/code_quality.md).

### Deliverables

- Signed assertions, cursor/delta/repair requests, and the `Orders` document encode and decode
  through canonical CBOR (`cborg` / `serialise`), with `decode . encode == id` proofs.
- `prodbox.cabal` gains the `cborg` / `serialise` dependencies on the library component.
- `distributed_gateway_architecture.md` drops the superseded non-CBOR wire language in favor of the
  canonical-CBOR contract.
- The lint stack's `Lint.Proto` stanza is renamed to `Lint.Cbor` (name only; the enforced rule set
  is unchanged) and is referenced by that name from `code_quality.md`.

### Validation

1. `prodbox dev check` exit 0.
2. `prodbox test unit` exit 0, including signed assertion/cursor/delta/repair and `Orders` CBOR
   round-trip coverage.
3. `prodbox test integration cli` and `prodbox test integration env` exit 0 on the home/local
   substrate.
4. Text-search proof shows no legacy non-CBOR wire language remains on the supported gateway path and the
   lint stanza reports as `Lint.Cbor`.

### Implementation Notes

- `src/Prodbox/Gateway/Types.hs` serializes `Orders`, while `State.hs` and `Peer.hs` derive signed
  assertion digests/HMAC inputs and cursor/delta/repair wire values from canonical CBOR bytes.
- `src/Prodbox/Gateway/Peer.hs` parses bounded `application/cbor` bodies for
  `POST /v1/peer/delta` and `POST /v1/peer/repair`; cursor reads use the same typed codec.
- `src/Prodbox/Gateway/Daemon.hs` signs canonical heartbeat/ownership/epoch-rotation assertions and
  transports only the bounded CBOR protocol.
- `prodbox.cabal` carries both `cborg` and `serialise` in the library component.
- Unit coverage includes `Orders`, signed assertion, cursor/delta, snapshot, and repair
  `decode . encode == id` proofs over the CBOR entrypoints.

### Closure Evidence

- `cabal build --builddir=.build exe:prodbox` exits 0.
- `cabal build --builddir=.build all --ghc-options=-Werror` exits 0.
- At Sprint `2.27` closure, `./.build/prodbox test unit` passed 1080/1080 for the then-current
  gateway CBOR surface; Sprint `2.31` replaces those transport fixtures with bounded signed
  assertion/delta/repair round-trip coverage.
- `./.build/prodbox test integration cli` passes 39/39.
- `./.build/prodbox test integration env` passes 39/39.
- Supported-gateway-path text search for legacy non-CBOR payload terms plus `payloadJson` and `payload_json`
  returns no matches.
- `./.build/prodbox dev check` exits 0 as the canonical local quality gate.

### Remaining Work

- None.

## Sprint 2.28: At-Least-Once Event Store to CBOR [✅ Done]

**Status**: Done (2026-07-02)
**Implementation**: `src/Prodbox/Daemon/Events.hs`
**Live-proof**: pending
**Independent Validation**: unit + CLI/env integration on the home/local substrate — the event-store round-trip and `markEventProcessed` idempotency suites plus `prodbox test integration cli`/`env` prove the CBOR payload encoding on the event-store's owned surface with no dependency on any later phase.
**Docs to update**: `documents/engineering/streaming_doctrine.md`, `documents/engineering/pulsar_messaging_doctrine.md`

### Objective

Migrate the durable Postgres at-least-once event payloads in `src/Prodbox/Daemon/Events.hs` from an
aeson `Value` column to canonical CBOR so the persisted event store uses the same canonical binary
codec as the peer transport (Sprint 2.27) and as
[pulsar_messaging_doctrine.md](../documents/engineering/pulsar_messaging_doctrine.md). The
at-least-once delivery and `markEventProcessed` IS-NULL guard contract from
[streaming_doctrine.md](../documents/engineering/streaming_doctrine.md) is preserved unchanged.

### Deliverables

- The at-least-once event payload persists as canonical CBOR bytes rather than an aeson `Value`,
  reusing the `cborg` / `serialise` codec landed in Sprint 2.27.
- Encode and decode round-trips and the idempotent `markEventProcessed` IS-NULL guard hold over the
  CBOR-encoded payloads.
- `streaming_doctrine.md` names canonical CBOR as the persisted at-least-once payload encoding.

### Validation

1. `prodbox dev check` exit 0.
2. `prodbox test unit` exit 0, including the event-store CBOR round-trip and at-least-once
   idempotency coverage.
3. `prodbox test integration cli` and `prodbox test integration env` exit 0 on the home/local
   substrate.

### Implementation Notes

- `src/Prodbox/Cbor.hs` now owns the shared `CborPayload` and JSON-shaped value-to-CBOR conversion
  helper used by both gateway signing and durable events.
- `src/Prodbox/Daemon/Events.hs` stores `eventPayload :: CborPayload`, derives `Serialise` for the
  durable event identifiers and `StoredEvent`, and exposes `encodeStoredEventCbor` /
  `decodeStoredEventCbor`.
- `src/Prodbox/Gateway/Types.hs` imports the shared `CborPayload`; Sprint 2.27's gateway wire codec
  remains unchanged on the wire.
- Unit coverage now includes a durable `StoredEvent` `decode . encode == id` CBOR proof while the
  existing `markEventProcessed` first-write-wins test continues to pin the IS-NULL guard.

### Closure Evidence

- `cabal build --builddir=.build exe:prodbox` exits 0.
- `cabal build --builddir=.build all --ghc-options=-Werror` exits 0.
- `./.build/prodbox test unit` passes 1081/1081, including the event-store CBOR round-trip and
  `markEventProcessed` first-write-wins coverage.
- `./.build/prodbox test integration cli` passes 39/39.
- `./.build/prodbox test integration env` passes 39/39.
- `./.build/prodbox dev check` exits 0 as the canonical local quality gate.

### Remaining Work

- None.

## Sprint 2.29: Pre-Vault Daemon Bootstrap Endpoint [✅ Done]

**Status**: Done 2026-07-05
**Implementation**: `src/Prodbox/Gateway/Daemon.hs`, `src/Prodbox/Gateway/Client.hs`,
`src/Prodbox/Gateway/Settings.hs`, `src/Prodbox/Vault/BootstrapBundle.hs`,
`charts/gateway/templates/service-nodeport.yaml`, `charts/gateway/templates/deployments.yaml`,
`test/unit/Main.hs`, `test/daemon-lifecycle/Main.hs`
**Independent Validation**: unit tests over request parsing/redaction and a
`prodbox-daemon-lifecycle` pre-Vault fixture that proves the REST listener binds before Vault
SecretRef resolution succeeds; no live cluster or later phase required.
**Docs to update**: `documents/engineering/distributed_gateway_architecture.md`,
`documents/engineering/vault_doctrine.md`, `documents/engineering/config_doctrine.md`,
`DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md`

### Objective

Give the in-cluster `prodbox` daemon a minimal pre-Vault REST mode so it can accept the
operator/test unlock-bundle password and perform Vault init/unseal/reconcile from inside the
cluster, without holding standing unseal authority.

### Deliverables

- A pre-Vault daemon config path that binds `/healthz`, `/readyz`, and
  `POST /v1/bootstrap/vault/ensure` before Vault-backed event keys, AWS credentials, or MinIO
  credentials resolve.
- A bounded, redacted bootstrap request/response contract. The password is accepted only in memory,
  never logged, never echoed, and never persisted; malformed or oversized bodies fail before any
  Vault or MinIO action.
- In-cluster MinIO and Vault clients for bootstrap: MinIO is reached through
  `minio.prodbox.svc.cluster.local`, Vault through the in-cluster Vault Service, and Vault's
  unauthenticated `sys/init`, `sys/seal-status`, and `sys/unseal` bootstrap APIs are the only
  sealed-Vault calls.
- Loopback-NodePort enforcement is treated as mandatory for password-bearing routes. A daemon can
  expose diagnostics without the firewall proof, but `bootstrap/vault/ensure` is unsupported when the
  loopback restriction is absent or unverifiable.
- Steady-state Vault-dependent routes continue to fail closed until Vault is initialized, unsealed,
  and reconciled.

### Validation

1. `prodbox test unit` covers route matching, request-size refusal, redaction, and the pure bootstrap
   decision table.
2. `cabal test --builddir=.build prodbox-daemon-lifecycle` includes a pre-Vault fixture proving the
   listener binds and the steady-state routes report unavailable without crashing.
3. `prodbox test integration cli` / `env` prove the command registry and generated docs stay aligned.
4. `prodbox dev check` remains green.

### Remaining Work

- None for Phase `2`. Sprint `4.42` consumes this endpoint from the lifecycle interpreter; Sprint
  `7.30` consumes the same daemon boundary for object-store/Pulumi backend access.

## Documentation Requirements

**Engineering docs to create/update:**

- `DEVELOPMENT_PLAN/development_plan_standards.md` - the SSoT for Standards N (Phase Independence)
  and O (Code-Local vs Live-Infra Proof) that this phase's Independent Validation line and
  forward-only `Blocked by` framing defer to; the engineering docs link to those standards rather
  than restating the doctrine.
- `documents/engineering/cli_command_surface.md` - Haskell gateway command surface, including the
  distinct native `gateway-partition` validation contract, the `--config <path>`-only
  daemon-launching flag set after Sprint 2.24 removes `--log-level` / `--port` / `--foreground`, and
  the `prodbox cluster federation register <child>` surface added by Sprint 2.26.
- `documents/engineering/cluster_federation_doctrine.md` - the root/child Vault transit-seal trust
  tree, the parent-owns-child-init-keys custody contract, downstream-cluster metadata as secret
  data, and the root-Vault-token gate on root federation state, owned by Sprint 2.26.
- `documents/engineering/config_doctrine.md` - the §2/§10 single-Dhall-surface contract that
  Sprint 2.24 enforces by deleting the daemon override flags, the §8 restart contract that
  Sprint 2.25 enacts as restart-based Orders promotion, and the unencrypted-basics surface that
  Sprint 2.26 keeps free of downstream-cluster identities.
- `documents/engineering/dependency_management.md` - gateway container-build posture under the
  canonical Docker doctrine, including the `ghcup` pin and no-symlink rule.
- `documents/engineering/distributed_gateway_architecture.md` - Haskell gateway implementation,
  retained DNS ownership doctrine, the authoritative peer-transport plus REST surface, and the
  §7.5 restart-based Orders-promotion rewrite plus the topology-honest fault-model reframe
  (home = three logical ranked peers on one physical host under shared fate; independent-host
  tolerance is the AWS / multi-host capability) landing with Sprint 2.25 (doctrine D4); for Sprint `2.29`, the pre-Vault daemon
  bootstrap endpoint and loopback-NodePort boundary.
- `documents/engineering/local_registry_pipeline.md` - gateway-container build, in-cluster
  `registry:2` loading, and native-host-architecture delivery doctrine.
- `documents/engineering/pulsar_messaging_doctrine.md` - the canonical-CBOR wire codec that
  Sprint 2.27 adopts for peer gossip and the `Orders` envelope and that Sprint 2.28 adopts for the
  persisted at-least-once event payloads.
- `documents/engineering/code_quality.md` - the lint stack whose `Lint.Proto` stanza Sprint 2.27
  renames to `Lint.Cbor` alongside the added `cborg` / `serialise` dependencies.
- `documents/engineering/secret_derivation_doctrine.md` - the canonical event-key / derive-context
  encoding consumed by the single-encoding consolidation and the encode/decode round-trip in
  Sprint 2.25.
- `documents/engineering/streaming_doctrine.md` - the at-least-once event-processing contract whose
  `markEventProcessed` IS-NULL guard Sprint 2.25 restores.
- `documents/engineering/tla/README.md` - formal model entrypoint and execution contract.
- `documents/engineering/tla_modelling_assumptions.md` - correspondence between the Haskell runtime
  and the model, including the split between native partition validation and `tla-check`, the
  restart-based Orders-promotion correspondence (Sprint 2.25 / doctrine D4), and the
  topology-honest fault-model note.
- `documents/engineering/unit_testing_policy.md` - Haskell gateway integration-suite ownership.
- `documents/engineering/vault_doctrine.md` - Vault is the sole secrets/KMS/PKI root; Sprint 2.26
  custodies each child cluster's init keys in the parent's Vault KV and records the parent's Transit
  key as the child's unseal authority; Sprint `2.29` records that root unseal remains
  operator-password-gated while the execution moves into the daemon.

**Product docs to create/update:**

- None.

**Cross-references to add:**

- Keep gateway and TLA+ doctrine linked back to [README.md](README.md).
- Add a backlink from `documents/engineering/cluster_federation_doctrine.md` to this phase for the
  gateway/CLI federation-trust surface owned by Sprint 2.26.

## Sprint 2.30: Gateway-Daemon Vault-Role SSoT [✅ Done]

**Status**: Done (2026-07-10)
**Implementation**: `src/Prodbox/Vault/RoleId.hs`, `src/Prodbox/Vault/Reconcile.hs`,
`src/Prodbox/Lib/ChartPlatform.hs`, `test/unit/Main.hs`
**Independent Validation**: `./.build/prodbox test unit` passes 1260/1260, including the exact
gateway-daemon policy-set assertion, the generated ChartPlatform gateway-release values proof, and
the no-duplicated-literal source guard; `./.build/prodbox dev check` exits 0. No later phase or live
infrastructure is required.
**Docs to update**: `documents/engineering/vault_doctrine.md`, `documents/engineering/helm_chart_platform_doctrine.md`

### Objective

Retire the 44e896f string-typo class on the supported generated-render path: the gateway-daemon
Vault role is one typed identity, so the generated chart value and the Vault-side role/policy
binding cannot drift into a 403.

### Deliverables

- `Prodbox.Vault.RoleId` defines the closed `VaultRoleId` inventory with
  `VaultRoleGatewayDaemon`, projected by `vaultRoleIdText` to `prodbox-gateway-daemon`.
- Both `defaultVaultReconcilePlan`'s `VaultKubernetesRoleSpec` and the supported generated gateway
  release values in `Prodbox.Lib.ChartPlatform` consume that projection; the former binds exactly
  `["prodbox-gateway", "gateway-gateway"]`.
- The generated-values test builds the AWS gateway deployment plan, decodes the gateway release's
  `chartReleasePlanValuesJson`, and proves `vault.role == vaultRoleIdText VaultRoleGatewayDaemon`.
  A separate source guard proves `ChartPlatform.hs` contains no duplicated
  `"prodbox-gateway-daemon"` literal.
- `charts/gateway/values.yaml` still records `prodbox-gateway-daemon` as the documented Helm-chart
  default. It is not the typed consumer proved here: the supported `prodbox charts reconcile
  gateway` generated values override this field from `VaultRoleId`. This sprint does not claim to
  single-source every gateway configuration value.

### Validation

1. `./.build/prodbox test unit` — passes 1260/1260; covers the exact two-policy set, the actual
   generated ChartPlatform gateway values, and the `ChartPlatform.hs` no-duplicated-literal guard.
2. `./.build/prodbox dev check` — exits 0.

### Remaining Work

- None. Standard-E note: this Phase-2 sprint edits the Phase-3-owned `ChartPlatform.hs` render by operator decision — the whole Vault-role SSoT is kept in one sprint rather than splitting the render consumption into Phase 3.

## Documentation Requirements

**Engineering docs to create/update:**

- `documents/engineering/vault_doctrine.md` - §12 gateway-daemon role bound to one `VaultRoleId`.
- `documents/engineering/helm_chart_platform_doctrine.md` - the values render sources the role from the shared identity, not a literal.

**Product docs to create/update:**

- None.

**Cross-references to add:**

- Former ledger row E (hardcoded Vault-role literal) is recorded under `Completed` in
  `legacy-tracking-for-deletion.md` for Sprint `2.30`.

## Sprint 2.31: Bounded Gateway State, Delta Gossip, and Credential-Gated DNS [✅ Done]

**Status**: Done (2026-07-10)
**Implementation**: `src/Prodbox/Gateway/Bounds.hs`, `State.hs`, `Orders.hs`, `Peer.hs`,
`Continuity.hs`, `ContinuityStore.hs`, `DnsAuthority.hs`, `ChildSchedule.hs`, `Daemon.hs`,
`Settings.hs`; versioned conditional Model-B operations in `src/Prodbox/Minio/`; the finite gateway
TLA+ model; `test/unit/GatewayBounded.hs`, `GatewayAuthority.hs`, `GatewayContinuity.hs`; and
`test/daemon-lifecycle/Main.hs`
**Live-proof**: pending — the restart-free deployed-substrate soak longer than the July 10 failure
interval is the non-blocking Standard-O axis owned by Sprint `5.16`; the profiling build and local
restart-free daemon heap capture are code-local evidence, not a substitute for that live soak.
**Independent Validation**: pure state-fold, delta/repair, frame-bound, continuity-crash, Orders,
and credential-authority properties run without Kubernetes or AWS; a real loopback daemon exercises
the bounded cursor endpoint and early oversized-frame rejection; the native partition fixture and
finite TLC model cover convergence/fault behavior independently of later phases.
**Docs to update**: `documents/engineering/distributed_gateway_architecture.md`,
`documents/engineering/tla_modelling_assumptions.md`,
`documents/engineering/resource_scaling_doctrine.md`,
`documents/engineering/streaming_doctrine.md`,
`documents/engineering/pulsar_messaging_doctrine.md`,
`documents/engineering/pure_fp_standards.md`,
`documents/engineering/haskell_code_guide.md`,
`documents/engineering/chaos_hardening_doctrine.md`,
`documents/engineering/README.md`

### Objective

The gateway's hot memory demand is finite by construction. Signed, idempotent ownership projection
uses bounded semantic state, bounded deltas/repair, retained emitter continuity, and explicit DNS
effect authority rather than an ever-growing heartbeat/event list or complete-log retransmission.

### Deliverables

- `GatewayState` retains keyed latest heartbeat and ownership evidence, one active Orders version
  plus one staged promotion slot, fixed-width per-emitter cursors, bounded signed replay/checkpoint
  evidence, and exactly 64 recent diagnostic hashes. There is no logical audit history and no raw
  append-only compatibility projection; the default replay capacity is eight signed assertions per
  emitter.
- Signed per-emitter monotonic deltas advance a vector cursor. When replay continuity is unavailable,
  a signed per-emitter semantic snapshot carries compacted heartbeat/ownership evidence plus a
  contiguous bounded suffix. Each emitter links only its own prior digest. Frame bytes, assertions
  per frame, parser input, rejection summaries, per-peer work, and process-wide in-flight frames
  are bounded; an oversized `Content-Length` is rejected from the header before body accumulation.
- One retained Model-B object per local emitter contains the Orders/emitter scope, committed
  fixed-width epoch/sequence/digest anchor, and at most one exact staged signed assertion plus next
  anchor. Publication is stage → durable acknowledgement/re-observation → publish → commit. Crash
  recovery republishes the exact staged bytes; sequence exhaustion rotates only through a durably
  staged signed invalidation and never wraps. Total peer restart recovers safe continuation anchors,
  not discarded semantic history; subsequent bounded peer exchange and new assertions re-establish
  the live semantic projection.
- Vault KV `secret/prodbox/gateway/continuity-admission/<node>` independently records first
  admission (policy path `secret/data/prodbox/gateway/continuity-admission/*`).
  Marker absence permits one initialize-if-absent operation; marker presence plus missing,
  corrupt, malformed, or unobservable authority refuses emission, claims, rotation, and DNS.
- Validated Orders admission rejects raw bytes, member cardinality, duplicate identities/ranks,
  node/endpoint/trust fields, encoded member contributions, and non-exact event-key membership before
  runtime maps, peer tasks, snapshots, or memory inputs are built.
- `DnsWriteAction` is constructible only from validated Route 53 inputs, the current local claim,
  deterministic credential generation, and a matching continuity fence. The interpreter receives a
  sealed AWS environment with metadata/profile discovery disabled. Generation change produces a
  typed restart decision; continuity is re-observed inside the same capacity-one lease before any
  public-IP or Route 53 child is constructed.
- The shared process-wide frame queue and `GatewayChildSchedule` enforce Sprint `1.60`'s aggregate
  scratch bound, capacity-one child peak, and deadline across peer/REST handlers, Model-B/MinIO,
  Vault, public-IP, Pulumi-object, and Route 53 subprocesses.
- `/healthz` and `/readyz` remain constant-time lifecycle-flag projections guarded against state
  traversal. `/v1/state` reports only bounded semantic/replay counts, hash/cursor diagnostics, and
  the already-observed local continuity disposition. Sprint `3.25` subsequently bound kubelet
  probes exclusively to the constant-time routes.
- The finite TLA+ model explores semantic kind/cursor agreement, overwriteable checkpoint repair,
  memory-losing crash/recovery, Orders staging/promotion, ownership/DNS safety, and credential
  readiness. Its finite model domains enable exhaustive TLC exploration and are abstraction bounds,
  never runtime bounds; native tests cover byte bounds, signatures, exact generations/fences, and
  concrete CBOR framing.

### Validation

1. `prodbox test unit` passes 1382/1382 and covers arbitrarily long/duplicate/reordered heartbeat histories,
   two-emitter partition-heal convergence and cursor monotonicity, Orders churn and production
   loader bounds, snapshot/repair tampering, epoch overflow, crash points, Model-B CAS/error
   classification, total-peer restart anchors, DNS effect counters, and sealed AWS environments.
2. `prodbox-daemon-lifecycle` passes 13/13 and exercises a real loopback cursor request, header-only oversized-frame
   rejection, bounded `/v1/state` schema/capacity, constant-time health/readiness goldens, and
   fail-closed continuity/DNS state.
3. `prodbox test integration gateway-partition` exits 0 with bounded-delta idempotency and
   single-writer/rejoin markers; CLI/env integration passes 45/45 and validates the generated
   command/config surfaces.
4. `cabal build --builddir=.build-profile --enable-profiling exe:prodbox` passes. A 61-second local
   restart-free `-hT -i0.05` daemon run with 500 successful bounded-state requests plus 500 bounded
   peer-listener requests records 16 samples and a 570,320-byte peak live heap against the generated
   268,435,456-byte RTS ceiling. The one-member pre-Vault fixture is profiling-path evidence, not a
   maximum-state or deployed stability claim; the deployed soak remains `Live-proof: pending` under
   Sprint `5.16`.
5. `prodbox dev tla-check` exhaustively checks all nine configured invariants: 606,637,449 states
   generated, 51,491,308 distinct states, depth 44, and queue 0. The fresh state counts and finite-
   domain abstraction boundary are recorded in
   `documents/engineering/tla_modelling_assumptions.md`.
6. `prodbox dev docs generate`, `docs check`, `lint docs`, and `prodbox dev check` pass; zero-residue
   scans find no current Haskell append-log symbols or `gateway.json` CLI/docs example.

### Remaining Work

- None. The deployed restart-free stability soak is tracked only as the non-blocking `Live-proof:
  pending` axis above and in Sprint `5.16`; it is not sprint-owned code work.

## Documentation Requirements

**Engineering docs to create/update:**

- `documents/engineering/distributed_gateway_architecture.md` - bounded semantic state, delta
  gossip, constant-time probes, and credential-gated DNS authority.
- `documents/engineering/tla_modelling_assumptions.md` - finite-state correspondence and explicit
  limits of tractability constraints.
- `documents/engineering/resource_scaling_doctrine.md` - gateway consumption of Sprint `1.60`'s
  runtime-memory plan.
- `documents/engineering/streaming_doctrine.md` - distinguish bounded peer-state anti-entropy from
  durable at-least-once event storage.
- `documents/engineering/pulsar_messaging_doctrine.md` - canonical-CBOR bounded gateway assertion,
  cursor/delta, and repair framing.
- `documents/engineering/pure_fp_standards.md` - bounded semantic replica state and explicit
  separation from durable event storage.
- `documents/engineering/haskell_code_guide.md` - bounded parser/frame admission, structured
  concurrency, and capacity-one child scheduling.
- `documents/engineering/chaos_hardening_doctrine.md` - finite peer/runtime fault budgets and the
  external stability-oracle handoff.
- `documents/engineering/README.md` - doctrine index entries and Phase-2 correspondence.

**Product docs to create/update:**

- `README.md` - current bounded-gateway baseline, command examples, and remaining external
  stability/probe ownership.

**Cross-references to add:**

- Sprint `3.25` consumes `/healthz` and `/readyz`; Sprint `5.16` separately supplies the external
  runtime-stability oracle.
- Keep `pure_fp_standards.md` and the other Sprint `2.31` doctrine pages linked back to this phase.

## Sprint 2.32: Single-Writer Emitter Actor and Whole-Transition Admission [✅ Done]

**Status**: Done (2026-07-20). The full code-owned target is implemented and independently
validated. It is additive and process-construction-exclusive: `JournalLeaseEmitter` owns the new
actor/journal/Lease path, while the public production wrapper continues to select
`LegacyModelBEmitter` until Standard-P qualification and later cutover. No runtime selector, shadow
writer, or dual-write path exists.
**Live-proof**: pending — deployed journal-volume, Kubernetes Lease, saturation, and restart evidence
remain a non-blocking Standard-O axis.
**Deployment qualification**: pending
**Design (verified 2026-07-19; implemented with all four corrections)**: the pure kernel
refines the TLA `journal.phase` protocol into an explicit `stage → fsync → publish → commit →
fsync` `EmitterPhase` (at most one non-idle value ⟹ structural single writer), holds one
`TransitionAdmission` + absolute `Deadline` across a whole transition, delegates the monotonic sequence/epoch
fence to `Continuity.nextAnchorFor` (no re-implementation, no drift), fences stale-mount completions by
`Incarnation`, and coalesces heartbeats in a bounded mailbox while never coalescing ownership/epoch/
recover. Adversarial corrections: (1) park the **unsigned** deferred request and re-sign it against the
post-rotation cursor (a parked *signed* transition fails `validateStagedRecord` after an epoch rotation);
(2) make epoch rotation a single source of truth at the actor's sign boundary and drop the unreachable
decide-time force-epoch branch, with a mistimed rotation message a no-op rather than an un-ready abort;
(3) keep a **size-triggered** checkpoint fold for the bounded repair floor so `emitterUnacked` cannot grow
unbounded behind a permanently-unreachable peer (ack-gating governs only the replay suffix); (4) treat
the forced-epoch rotation and the parked advance as **two separately-ticketed** transitions rather than
one spanning ticket that could exhaust its deadline. The implementation preserves all four.
**Implementation**: ✅ **Fully landed.** `Gateway/Emitter/Kernel.hs` owns the pure
`EmitterState`/`EmitterIntent`/`EmitterEffect`/`EmitterStep` decide-evolve machine; the private
`InFlight` value binds the `DurableKind`, exact `StagedRecord`, `TransitionAdmission`, absolute
`Deadline`, and `Incarnation` across the five effects. `Gateway/Emitter/Mailbox.hs` and
`Gateway/Emitter/Actor.hs` provide one capacity-certified worker with a bounded typed queue,
freshest-heartbeat coalescing, never-coalesced ownership/recovery work, immediate saturation
refusal, and no second state owner.

`Gateway/Emitter/Journal.hs` is the bounded AEAD-encrypted, identity/event-key-bound local journal.
It validates canonical and symlink-safe roots, holds a process-local guard plus a long-lived POSIX
filesystem lock, and publishes through temporary write, file fsync, rename, and directory fsync.
The journal and initial projection are durable **before** the independent admission marker is
persisted and read back. A crash in that gap resumes the authenticated existing journal; the inverse
(marker present but journal missing) fails closed unless an exact identity-bound indexed retirement
receipt is admitted. Every mount fsyncs a monotonic non-zero incarnation before publication.
`Gateway/Emitter/Lease.hs` and `Gateway/Emitter/KubernetesLease.hs` bind the exact emitter,
incarnation, journal digest, and journal-identity digest into a read-back-verified
`coordination.k8s.io/v1 Lease`; the Lease is one fence, never the sole fence.

Recovery rewinds every signed interrupted phase to the last durable staged record, restores the
authenticated repair floor and contiguous exact suffix before republication, and answers the
originating request only after the final projection fsync. Lease loss clears readiness and the sole
recovery worker serially re-drives the retained bytes after reacquisition. Peer acknowledgements
advance through the same actor and are adopted into volatile peer cursors only after their projection
fsyncs. Local restart recovery restores exactly one emitter from its journal; remote peer
delta/checkpoint repair remains a distinct monotonic replica mechanism and cannot replace local
authority.

The version-3 durable projection retains one bounded `Maybe ContinuityDigest` for the authenticated
previous Orders scope. `migrateEmitterOrders` sets or replaces it; ordinary commits, acknowledgement
fsyncs, checkpoint compaction, incarnation rebase, encode/decode, and restore preserve it. Pending,
in-flight, latest, suffix, or checkpointed Orders-migration evidence that disagrees with that digest
is rejected. On ordinary recovery the daemon re-arms the exact State admission from the retained
digest before replay. Both a migrated-projection crash before publication and a same-process final-
fsync refusal therefore re-drive the exact staged bytes and converge without relabelling evidence.

`Gateway/Daemon.hs` composes that target without using the global `ChildSchedule`: target REST and
Route 53 calls use operation-specific capacity-one lanes with immediate refusal and one propagated
absolute deadline, and target DNS mutation uses the bounded native Route 53
`ChangeResourceRecordSets`/`GetChange` client through `INSYNC`. The legacy scheduler and AWS CLI
remain only in the mutually exclusive rollback topology required by Standard P.
`Gateway/Emitter/Persistence.hs` supplies the typed claim-side projection for stable StatefulSet
identity, the home node-pinned retained `hostPath`, the AWS manual retained claim with
`ReadWriteOncePod`, and exact Lease RBAC. The Phase-3 chart/render foundation is a distinct
consumer; production activation remains plan-tracked and is not Sprint-2.32 implementation work.

`documents/engineering/tla/gateway_orders_rule.tla` models the complete five-step journal protocol,
crash/Lease-loss rewind, overlapping incarnations, the OS-lock + fsynced-incarnation + Lease fence,
admission/deadline/exact-record rejection, per-peer acknowledgements, bounded checkpoint repair,
and the composed DNS gate.
**Independent Validation**: ✅ pure/property and interpreter suites pass for bounded State
(`43/43`), Kernel (`45/45`), Actor (`11/11`), Journal (`20/20`), Lease (`31/31`), and Persistence
(`5/5`). The Journal suite uses a self-exec cross-process fixture: a canonical holder excludes a
symlink-alias contender, survives SIGKILL as exact durable bytes, and remounts at incarnation `2`.
The Sprint-2.32 daemon-lifecycle group passes `14/14`; the complete lifecycle suite passes `28/28`,
including commit-before-response, publish-before-commit crash, Lease-loss rewind, exact restart,
peer-ack fsync refusal/retry, migrated-projection restart, same-process migration final-fsync
refusal, and indexed retirement. Full unit passes `1974/1974`. The native
`gateway-partition` validation passes with `EMITTER_PIPELINE_COMPOSED`, `OFFLINE_REPAIR_EXACT`,
`DURABLE_ACK_ADVANCED`, `CHECKPOINT_COMPACTION_BOUNDED`, `RESTART_EXACT_BYTES`,
`WRONG_INCARNATION_REJECTED`, and `WRONG_DIGEST_REJECTED` all true. Canonical
`prodbox dev tla-check` exits `0`: 7,139,920 generated states, 781,710 distinct states, depth 44,
zero states left on the queue, and all 16 invariants pass. Fresh corrected CLI and env integration
each pass `49/49`; docs check/lint, `git diff --check`, and the final-tree `prodbox dev check` all
exit `0`.
**Docs to update**: `documents/engineering/lifecycle_control_plane_architecture.md`,
`documents/engineering/distributed_gateway_architecture.md`,
`documents/engineering/tla_modelling_assumptions.md`,
`documents/engineering/resource_scaling_doctrine.md`, and
`documents/engineering/chaos_hardening_doctrine.md`

### Objective

Make one actor the sole owner of each local emitter's continuity state and serialize an entire
`stage -> fsync -> publish -> commit -> fsync` transition, eliminating races between heartbeat and
continuity loops and the overloaded global child-process permit on the target path.

### Deliverables

- Define pure `EmitterState`, `EmitterIntent`, and `EmitterEffect` ADTs plus the total `EmitterStep`
  decision result; only the actor worker owns and evolves the current state.
- Route heartbeat, ownership, rotation, and recovery requests through a bounded typed mailbox.
  Coalesce superseded heartbeat intents but never ownership or epoch transitions.
- Hold one private kind/record-fenced `TransitionAdmission` and absolute deadline across the whole
  logical transition; no phase may release and reacquire a global permit.
- Use a dedicated encrypted identity-bound local journal/fsync interpreter; the heartbeat path has
  no MinIO, generic object-store, Vault-login, or subprocess client. Remove the gateway-wide
  capacity-one subprocess scheduler from target continuity and REST work while Standard P retains
  the mutually exclusive legacy rollback implementation.
- Enforce one actor across process incarnations with an exact mount, exclusive OS filesystem lock,
  Kubernetes Lease/incarnation witness, and fsynced monotonically increasing emitter incarnation
  before readiness/publish; the Lease is not the sole fence and peers reject stale incarnations.
  Supply the typed substrate-exact persistence projection: stable StatefulSet identity, EKS CSI EBS
  `ReadWriteOncePod`, and a home node-pinned retained `hostPath`/local-PV coordinate. Physical
  chart/PV/EBS rendering and public activation remain distinct plan-tracked consumers.
  Missing-journal recovery requires the explicit indexed emitter-retirement program.
- Retain the latest signed assertion/previous anchor and peer-ack projection. Restart republishes
  unacknowledged state; ownership transitions compact only after every current peer acknowledges or
  a signed checkpoint makes the transition part of the bounded repair floor.
- Revise the continuity protocol/model so crash points around
  `stage -> fsync -> publish -> commit -> fsync`, replay, and restart recovery are explicit and
  model-checked.

### Validation

1. State-machine properties prove one writer, monotonic sequence/fence, idempotent replay, and
   crash-resume convergence; real overlapping-process fixtures plus the finite overlapping-Pod
   model prove lock/incarnation exclusion on the code-owned surface.
2. Deterministic schedules reproduce and then reject the former re-observation mismatch race.
3. Saturation tests prove bounded mailbox memory, heartbeat coalescing, ownership preservation,
   prompt overload rejection, and deadline propagation.
4. Daemon-lifecycle and gateway-partition suites cover commit-before-peer-response, restart
   republish, peer acknowledgments, checkpoint compaction, offline repair, and emitter retirement.
5. `prodbox dev tla-check` and `prodbox dev check` pass with recorded fresh state counts.

### Remaining Work

- None (code-owned). Kernel, actor, mailbox, encrypted journal, journal-first admission, filesystem
  lock, Lease/incarnation fence, durable projection, exact recovery, acknowledgement/checkpoint
  repair, authenticated Orders migration, target operation lanes, native Route 53, typed
  persistence projection, formal model, and local validation fixtures are landed.
- The later Phase-3 chart foundation consumes the typed persistence projection for physical
  StatefulSets, PVs, EBS identities, reclaim policy, and RBAC. Its remaining production adoption is
  plan-tracked and is not deferred Sprint-2.32 implementation.
- Standard-O live proof and Standard-P deployment qualification remain pending. Until Standard P
  is proven, `LegacyModelBEmitter` remains the default production topology and its registered
  rollback routes/scheduler stay Pending Removal; the target is not an operational cutover.

## Documentation Requirements

**Engineering docs to create/update:**

- `documents/engineering/distributed_gateway_architecture.md` - single-writer actor and bounded
  mailbox.
- `documents/engineering/tla_modelling_assumptions.md` - actor/protocol correspondence.
- `documents/engineering/resource_scaling_doctrine.md` - gateway service-rate evidence.
- `documents/engineering/chaos_hardening_doctrine.md` - actor crash and saturation matrix.
- `documents/engineering/lifecycle_control_plane_architecture.md` - gateway responsibility
  boundary.

**Product docs to create/update:**

- `README.md` - gateway role after lifecycle extraction.

**Cross-references to add:**

- Link the actor to Sprint `1.62` capacity evidence and Sprint `5.19` temporal qualification.

## Sprint 2.33: Minimal Bootstrap Broker and Gateway Scope Cut [✅ Done]

**Status**: Done — the Bootstrap Broker runtime role, prepared-init custody protocol, gateway
scope cut, role-indexed config split, and loopback crash matrix are landed and validated on the
code-owned surface. Closing this sprint recloses Phase `2`.
**Deployment qualification**: pending
**Live-proof**: pending — the composed MinIO→broker→Vault→observed-handoff bring-up on a real
cluster is the non-blocking Standard-O axis. Phase 3 supplied the chart/render foundation; the
current production composition remains pre-cutover.
**Implementation**: ✅ landed — the closed `RuntimeRole`/`RuntimeConfigIdentity` split in
`src/Prodbox/Runtime/Role.hs` (each role decodes only its own mounted Dhall; no shared daemon
config); the full `src/Prodbox/Bootstrap/Broker/` subsystem (closed `BrokerRoute` registry with
only the four bootstrap/vault/baseline/PKI operation classes plus child custody/recovery — no
generic KV/mesh/DNS/Pulumi/SES/authority-CAS/target-secret route; `Engine`, `Custody`,
`PgpBoundary`, `SecretWorker`/`EngineSecretWorker`, `Server`, `Client`, `Fake`, `RequestJournal`,
`Admission`, `Fence`, `StoreBoundary`, `Settings`, `Program`); the `bootstrap-broker start
<config-path>` CLI with role dispatch; removal of the pre-Vault handlers from
`Gateway/Daemon.hs`/`Gateway/Client.hs`; the CLI `vault ...` surface compiling pre-Vault requests
into broker-mediated programs; and the `checkBootstrapBrokerIsolation` negative source/route lint in
`CheckCode.hs` that fails the build on a reintroduced pre-Vault route in the Gateway registry or a
generic-object-store escape in the Broker registry.
**Independent Validation**: ✅ a loopback Bootstrap Broker with fake MinIO/Vault interpreters proves
init/unseal/baseline/PKI/status/rotation behavior, the prepared-init PGP-recovery/password-AEAD
custody protocol and its crash/resume matrix, generated-root session accessor audit/revoke/absence,
child-custody delivery/recovery, HTTP bounds/drain, idempotency, and gateway route absence without
Kubernetes, AWS, or a later phase. Evidence: `prodbox dev check` exit 0; `prodbox test unit`
2193/2193 (incl. the ten `BootstrapBroker*` suites); `prodbox test integration cli` 52/52 and
`env` 52/52; `prodbox-daemon-lifecycle` 28/28.
**Docs to update**: `documents/engineering/lifecycle_control_plane_architecture.md`,
`documents/engineering/vault_doctrine.md`,
`documents/engineering/distributed_gateway_architecture.md`,
`documents/engineering/bootstrap_readiness_doctrine.md`, and
`documents/engineering/config_doctrine.md`

### Objective

Extract the irreducible pre-Vault recovery capability into a small broker whose dependency set is
MinIO plus static bootstrap material, leaving gateway mesh availability irrelevant to Vault
initialization or unseal.

### Deliverables

- Add a closed `RuntimeRole`/command selection for `BootstrapBroker` distinct from
  `GatewayRuntime`; each role decodes only its own Dhall configuration.
- Limit the broker API to bootstrap status, initialize/unseal/seal, unlock-bundle/key rotation,
  allowlisted Vault baseline reconciliation, and bounded PKI status/test issuance. It owns no
  generic KV, mesh, DNS, Pulumi, SES, authority CAS, or target-secret route.
- Before first init, bind the exact empty Vault storage generation and transaction ID. Generate the
  PGP recovery-recipient keypair, password-AEAD-seal its private key plus the recovery/burn public-
  key fingerprints into a `PreparedInitEnvelope` in bootstrap MinIO, and read it back before
  `/sys/init`; the pinned/audited burn public key's private material existed only inside an isolated
  destructive ceremony, was never exported, was destroyed before adoption, is never accepted,
  retained, or available to prodbox, and has no known holder; prodbox never decrypts or uses the
  initial token. Persist/read-back Vault's PGP-encrypted share
  response, decrypt it only through the prepared recipient, atomically promote the final password-
  AEAD unlock bundle, then delete/read-back the prepared private-key envelope. A crash re-prompts
  and resumes that transaction. Never decrypt or use the burn-encrypted initial token. An init that
  applied but yielded no durable encrypted response is explicit ambiguity; only a confirmed reset
  of that proven-pristine generation may retry.
- Generate a separate short-lived root session only after recovery custody is durable. Serialize
  these sessions, journal non-secret accessors, remove stale root-policy accessors before work,
  read back the allowlisted baseline, revoke, and prove accessor absence through the broker-only
  auditor. Later normal reconcile uses the dedicated Kubernetes-auth provisioner role.
- Apply the same protocol to child Vaults: journal PGP-encrypted shares locally, generation-CAS
  deliver them to parent custody, and delete the local receipt only after exact acknowledgment.
  Later recovery is a one-time parent-to-attested-child encrypted delivery. No usable initial root
  token is serialized anywhere. Root unseal shares exist only inside the password-AEAD final unlock
  bundle; child recovery shares remain encrypted in parent custody; no plaintext share appears in
  config, authority state, logs, or an unencrypted receipt.
- Authenticate and bind the broker to a loopback-restricted Service surface with bounded request
  bodies, absolute deadlines, idempotency keys, redaction, and explicit draining.
- Remove pre-Vault lifecycle endpoints and static MinIO bootstrap credentials from gateway pods.
- Make post-unseal handoff an observed state transition; the broker does not become the
  post-Vault Lifecycle Authority.

### Validation

1. Exhaustive role-dispatch tests prove each binary role exposes only its allowed routes and
   configuration fields.
2. Broker fixtures cover empty, initialized-sealed, unsealed, corrupt bundle, unavailable MinIO,
   every crash before/after prepared-recipient read-back, init request, encrypted-response receipt,
   final-bundle promotion, prepared-envelope deletion, custody acknowledgment, generate-root,
   accessor/baseline/revoke/absence read-back, applied-without-response pristine reset,
   established-Vault reset refusal,
   normal provisioner login, orphan-root cleanup, PKI role bounds, burn-recipient initial-token
   non-use, cancellation, and restart.
3. Negative source/route lint proves gateway code carries no bootstrap credential or endpoint.
4. Daemon lifecycle, CLI/env integration, and `prodbox dev check` pass.

### Remaining Work

- None (code-owned). The broker/runtime role split, prepared-init custody protocol, route removal,
  config split, and loopback crash matrix are landed and validated.
- The later Phase-3 chart/render foundation supplies separate role shapes. The composed real-cluster
  bring-up remains the non-blocking Standard-O live-proof axis, and current activation and
  deployment qualification remain governed by the plan status and Standard P.

## Documentation Requirements

**Engineering docs to create/update:**

- `documents/engineering/lifecycle_control_plane_architecture.md` - bootstrap role and handoff.
- `documents/engineering/vault_doctrine.md` - pre-Vault broker authority and credentials.
- `documents/engineering/distributed_gateway_architecture.md` - removed bootstrap scope.
- `documents/engineering/bootstrap_readiness_doctrine.md` - MinIO→broker→Vault ordering.
- `documents/engineering/config_doctrine.md` - role-indexed mounted Dhall configuration.

**Product docs to create/update:**

- `README.md` - bootstrap and gateway process boundaries.

**Cross-references to add:**

- Link the Phase-3 chart-rendering adoption boundary without making this phase depend on Phase 3.

## Sprint 2.34: Compiled Service Boundary and Latched Readiness [✅ Done]

**Status**: Done
**Deployment qualification**: pending
**Live-proof**: pending — Standard P retains the legacy rollback topology until the composed
journal/Lease replacement is qualified. Sprint `2.32` landed the target topology's authority fact
without changing this sprint's code-local closure.
**Implementation**: ✅ **Fully landed.** Compiled service boundary — `src/Prodbox/Gateway/Routes.hs`
(closed `GatewayRoute` registry), the total-case dispatcher `dispatchGatewayRoute`/`dispatchPatternRoute`
in `src/Prodbox/Gateway/Daemon.hs`, the client URL projections in `src/Prodbox/Gateway/Client.hs`, the
probe projection + `GatewayProbeEndpoint` deletion in `src/Prodbox/Gateway/Probe.hs`, and the
`ObjectStore`/`TargetSecret` path constants now projected from `routePattern`. Readiness —
`src/Prodbox/Gateway/Readiness.hs` (`computeReadiness` over drain phase / emitter authority /
workers started), the deleted unconditional serve-start `Ready` write, the rollback topology's
continuity-authority latch, the `/readyz` precheck on the lifecycle-restore gate (`TestRestore.hs` +
`queryReadyz` in `Gateway/Client.hs`), and readiness `failureThreshold` 3 → 6. Sprint `2.32` landed
the target topology in which emitter authority is a current, fail-closed journal/Lease/recovery witness;
there is no environment-variable readiness bypass. Chart statics —
`src/Prodbox/Gateway/ChartStatics.hs`, the `valuesForGateway` +
`values.yaml` `gateway-chart-statics.values` generated section, the `.Values.serviceAccount.name`
template binding, the forbidden-raw-literal chart lint, and the deployed-values-equal-compiled
conformance gate in `runConformanceTier`. Unit suites `test/unit/GatewayReadiness.hs` and
`test/unit/GatewayChartStatics.hs`.
**Independent Validation**: ✅ pure route-registry non-overlap/round-trip tables
(`test/unit/GatewayRoutes.hs`); ✅ readiness projection tables proving no admission without current
emitter authority, fail-closed authority loss, and absorbing drain (`test/unit/GatewayReadiness.hs`);
✅ a conformance
spec proving deployed helm values equal the compiled statics projection
(`test/unit/GatewayChartStatics.hs` + the `runConformanceTier` gate); ✅ the lifecycle-gate `/readyz`
precheck composition proof (fail-closed, round trip not attempted while `/readyz` unready). Evidence:
warning-clean `-Werror` build, fourmolu/hlint clean, unit 1610/1610, `prodbox-daemon-lifecycle` 13/13
(real daemon `/healthz`/`/readyz` ready + SIGTERM drain to 503 + the pre-Vault invariant), CLI+env
integration 49/49, and `prodbox dev check` exit 0 (env-read lint scope, generated-section drift, chart
lint, conformance tier). All pre-cluster.
**Docs updated**: `documents/engineering/lifecycle_control_plane_architecture.md` (§10.2, already
aligned), `documents/engineering/helm_chart_platform_doctrine.md` (§1A chart lint + gateway
chart-statics contract), `documents/engineering/distributed_gateway_architecture.md` (already
aligned), `documents/engineering/bootstrap_readiness_doctrine.md` (§2.1 latched-readiness note +
Sprint `1.61` rescope pointer), and `documents/engineering/config_doctrine.md` (§10 readiness has no
configuration or test bypass).

### Objective

Close the `F-READY` mechanism of counterexample `LCPC-2026-07-11` structurally: make every
kubelet-facing gateway service contract a projection of one compiled route registry, and collapse
the divergent readiness notions into a single pure latched projection.

### Deliverables

- Define a closed `GatewayRoute` ADT (`Enum`/`Bounded`); `routePattern` is the one place any daemon
  path string exists, and `routeClass` distinguishes liveness, readiness, diagnostic, and RPC
  routes. The daemon dispatcher becomes a total case over the registry, so a registered route
  without a handler is a compile error under `-Werror`; clients and chart probe rendering are
  projections of the same registry; the `GatewayProbeEndpoint` enum is deleted; a kubelet probe
  bound to a non-probe route is unbuildable by smart constructor.
- Make readiness one pure projection: `computeReadiness` over drain phase, emitter authority, and
  worker inputs. The rollback topology requires and latches its validated continuity startup; the
  Sprint `2.32` target topology supplies a current journal/Lease/recovery witness that may clear on
  Lease loss. Deep diagnostics stay on the state route. The unconditional serve-start `Ready` write
  is deleted. The lifecycle gate keeps its end-to-end round trip and gains a `/readyz` precheck, so
  lifecycle-ready implies kubelet-ready by construction; readiness `failureThreshold` rises 3 → 6.
- Introduce a `GatewayChartStatics` record feeding both the deployed values JSON and new generated
  sections for ports, NodePort, ServiceAccount, and Vault-role identities; a chart lint forbids the
  raw literals in hand-written templates.
- Absorb the exact-readiness-evidence deliverable rescoped out of Sprint `1.61` (see the 2026-07-12
  scope note in [phase-1-runtime-cli-aws-foundations.md](phase-1-runtime-cli-aws-foundations.md)).

### Validation

1. Pure route-registry tables prove non-overlap and pattern round-trip over the closed registry.
2. A conformance spec proves the deployed helm values equal the compiled registry/statics
   projections.
3. Readiness projection tables prove no admission without current emitter authority, fail-closed
   target authority loss, and absorbing drain; the daemon fixture proves the rollback topology does
   not publish its monotone latch before validated startup recovery.
4. All of the above run pre-cluster; `prodbox dev check` and `prodbox test unit` pass.

### Current Validation State

All three deliverable groups are ✅ landed and validated pre-cluster.

- **Compiled service boundary**: the closed `GatewayRoute` registry (`Enum`/`Bounded`,
  `routePattern`/`routeClass`/`routeForPath` and the `kubeletProbeRoute` smart constructor) is the
  single source of every daemon path string; the daemon dispatcher is a total `case` over it (a
  registered route without an arm is a `-Werror` compile error); the daemon diagnostics, the gateway
  client (`Prodbox.Gateway.Client`), the chart probe paths (`Prodbox.Gateway.Probe`,
  `GatewayProbeEndpoint` deleted), and the `ObjectStore`/`TargetSecret` wire-path constants are all
  projections of `routePattern`.
- **Readiness**: `computeReadiness` (`src/Prodbox/Gateway/Readiness.hs`) folds cached drain phase,
  emitter authority, and worker-started state with zero backend I/O. The rollback topology sets its
  monotone authority latch in `installRuntime`'s continuity-publish STM transaction only after a
  validated `StartupRecovery`. The Sprint `2.32` target topology instead supplies a current
  journal-lock/Lease/recovery witness and clears readiness on Lease loss. The lifecycle-restore gate
  has a `/readyz` precheck (lifecycle-ready ⟹ kubelet-ready), readiness `failureThreshold` is 3 → 6,
  and no environment-variable hook can bypass either topology's authority gate. This absorbs the
  exact-readiness-evidence deliverable rescoped from Sprint `1.61`.
- **Chart statics**: `Prodbox.Gateway.ChartStatics` is the one source for ports / NodePort /
  ServiceAccount / Vault-role; `valuesForGateway` and the generated `gateway-chart-statics.values`
  section project from it, the templates render `{{ .Values.serviceAccount.name }}`, a chart lint
  forbids the raw literal, and a `runConformanceTier` gate proves the committed `values.yaml` equals
  the compiled projection.

Evidence: warning-clean `-Werror` build, fourmolu/hlint clean, unit 1610/1610 (incl.
`test/unit/GatewayRoutes.hs`, `GatewayReadiness.hs`, `GatewayChartStatics.hs`),
`prodbox-daemon-lifecycle` 13/13 (real daemon `/healthz`/`/readyz` ready + SIGTERM drain to 503 + the
pre-Vault invariant), CLI+env integration 49/49, and `prodbox dev check` exit 0 (env-read lint scope,
generated-section drift, chart lint, conformance tier).

Standard O: live qualification of the composed target topology remains pending; this sprint's
route, projection, and chart-static surfaces remain independently validated pre-cluster.

### Remaining Work

- None (code-owned). Current-revision composed deployment qualification remains pending under
  Standard P.
- The Foundation Epoch's Phase-2 slice is complete; no pending Foundation work or blocked edge
  remains in this sprint. Other phases own their current Foundation-Epoch statuses.

## Documentation Requirements

**Engineering docs to create/update:**

- `documents/engineering/lifecycle_control_plane_architecture.md` - compiled service boundary and
  readiness projection.
- `documents/engineering/helm_chart_platform_doctrine.md` - probe/route single-source rule and the
  forbidden-literal chart lint.
- `documents/engineering/distributed_gateway_architecture.md` - current-authority readiness semantics
  superseding the unconditional serve-start readiness write.
- `documents/engineering/bootstrap_readiness_doctrine.md` - readiness-evidence rescope pointer
  (Sprint `1.61` → Sprint `2.34`).

**Product docs to create/update:**

- `README.md` - readiness wording aligned with the latched single-projection doctrine.

**Cross-references to add:**

- Link the Sprint `1.61` scope note in
  [phase-1-runtime-cli-aws-foundations.md](phase-1-runtime-cli-aws-foundations.md) and the
  deletion-ledger rows owned by this sprint in
  [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md).

## Sprint 2.35: Configurable Certificate Scope Algebra and Derived Edge Projections [✅ Done]

**Status**: Done (2026-07-20). The full code-owned surface is closed: pure `CertScope` algebra,
Tier-0 `cert_scopes` plus fail-fast validation of every configured substrate served host, derived
keycloak public-edge `Certificate.spec.dnsNames`, exact canonical scope-set TLS retention/restore,
and the fail-closed `edge status` certificate-expiry rungs. The default exact-host configuration
retains its historical object-key bytes. Wildcard/multi-SAN sets use a path-safe canonical key, and
a different SAN set receives a different coordinate because cert-manager treats it as a distinct
issuance specification. `impliedBy` remains the coverage/admission order only. Live serving proof is
owned by the now-unblocked Sprint `5.22`.
**Live-proof**: pending — Sprint `5.22` owns the live serving proof.
**Deployment qualification**: pending
**Implementation**: ✅ **pure algebra landed** — `src/Prodbox/Tls/CertScope.hs` defines
smart-constructed `Fqdn` / `DelegatedZone`, `CertScope` (`ScopeExact` / `ScopeWildcard DelegatedZone`),
the canonical (deduped, ordered) `CertScopeSet` built by `mkScopeSet` (which rejects a wildcard
anchored at an undeclared delegated zone), total `covers` with the strict wildcard boundary
(`*.z` covers single-label children of `z` only — never the apex, never a deeper name), the
narrower-or-equal partial order `scopeImpliedBy` / `impliedBy` (with `*.a.z` NOT `impliedBy` `*.z`),
`bindListener` (rejecting an uncovered host), and the derived projections
`certScopeSetDnsNames` / `renderCertScopeSet` (the one set → dnsNames + retention-key views).
✅ **Tier-0 config field + fail-fast validation + settings-pin replacement landed (2026-07-19)**:
`DomainSection` gains `cert_scopes :: [Text]` (empty = today's exact served host, so the default is
behavior-identical); the generated schema regenerated via `config schema`; the config emitter and the
binary-sibling `prodbox.dhall` round-trip it; and `Settings.validateSupportedPublicHost` is replaced by
`validateConfiguredCertScope`, which builds the scope set from config (delegated zones anchored on the
served host's parent zone plus the AWS subzone), rejects a wildcard at an undelegated zone and an
uncovered served host fail-closed, and preserves the `domain.demo_fqdn must not be empty` error. The
`mkScopeSet` reduction (a wildcard subsumes its exact children) makes the canonical set minimal so
`impliedBy` is a genuine partial order — a subtlety the antisymmetry property test caught.
✅ **derived public-edge `dnsNames` landed (2026-07-19)**: the keycloak public-edge `Certificate`
`dnsNames` is now a projection of the one configured scope set, keyed on each substrate's served host.
`Settings.certScopeSetForServedHost` / `certDnsNamesForServedHost` parameterize the scope set by served
host (so the home served host and the AWS subzone each default to exactly their own FQDN);
`ChartPlatform.valuesForKeycloak` injects `gateway.certDnsNames` from that projection; and
`charts/keycloak/templates/gateway.yaml` renders `dnsNames` as a `range` over it. This is a values-
injection projection (not a static generated block) because the dnsNames are substrate-dependent —
home served host vs. AWS subzone — which a `const` generated section cannot capture; the
`charts/gateway/templates/certificates.yaml` daemon mesh cert is per-node internal and is intentionally
NOT derived from the public scope set. Proven behavior-identical for the default (empty `cert_scopes`)
by an isolated `helm template` render (`dnsNames: ["test.resolvefintech.com"]`) and correctly projecting
a widened scope. ✅ **`edge status` certificate-expiry rungs landed (2026-07-19)**: `Prodbox.Host`
gains the pure fail-closed `CertExpiryRung` classifier (`classifyCertificateExpiry` over the already-fetched
cert-manager `Certificate public-edge-tls` document + wall-clock now) — an absent/unparseable
`status.notAfter` or `status.renewalTime` is `certificate-unobservable` (never "current"); `notAfter <= now`
is `certificate-expired` (terminal, priority); `renewalTime <= now < notAfter` is `certificate-renew-due`;
otherwise `certificate-current`. No repo-side renewal-window recompute — prodbox reads cert-manager's
committed timestamps and only compares. The `edge status` report renders `CERTIFICATE_EXPIRY=<rung>`.
✅ **exact canonical scope-set retention landed (2026-07-20)**:
`PublicEdge.publicEdgeTlsRetentionKey` now consumes the typed `CertScopeSet`, retains the historical
single-exact-host key byte-for-byte, and path-escapes wildcard/comma syntax so certificate wildcards
cannot become IAM resource-pattern wildcards. `ChartDeploymentPlan` carries the exact compiled scope
set for its selected substrate; deploy and delete plans expose the resulting coordinate, and delete
planning is now substrate-aware rather than silently falling back to home-local. Retain-on-ready,
pre-delete retention, and restore-before-issue all address only that exact key. A new SAN set orders
once and is retained under its own coordinate; returning to a still-valid previously retained exact
set may reuse it. Settings validation also binds the configured AWS subzone host when present, so an
explicit scope that covers home but not AWS fails before execution.
**Independent Validation**: ✅ pure property tests landed in `test/unit/CertScopeSuite.hs`
(registered in `test/unit/Main.hs`): boundary tables for the wildcard semantics (apex / single-label
child / two-label-deep), the `impliedBy` structural cases (`*.a.z` not `impliedBy` `*.z`), `mkScopeSet`
rejection of undeclared-zone wildcards, `bindListener` rejection of uncovered hosts, the canonical
`dnsNames` / retention-key projection, the reduction of a redundant exact under a wildcard, and
QuickCheck properties (100 cases each) for `impliedBy` reflexivity / transitivity / antisymmetry and
coverage-preservation under widening (admission-order soundness). The exact-retention tests prove
that a scope set and a merely covering wider set serialize to different coordinates, that the
single-host default retains its historical key, and that wildcard/multi-scope syntax is path-safe.
The config-field validation is
proven by direct `validateConfiguredCertScope` tests in the `settings` suite (default scope covers the
served host; a delegated wildcard is accepted; an empty host, an undelegated-zone wildcard, and an
uncovered served host are each rejected fail-closed; an explicit set that covers home but not the
configured AWS served host is also rejected). The derived keycloak `dnsNames` is proven by
three `settings`-suite `certDnsNamesForServedHost` tests (default served host, AWS-subzone served host,
widened wildcard) plus an isolated `helm template` render showing the default renders
`dnsNames: ["test.resolvefintech.com"]` (behavior-identical) and a widened set renders both entries.
The `edge status` certificate-expiry rungs are proven by 7 `host`-suite `classifyCertificateExpiry` tests
over fake cert-manager `Certificate` JSON (current / renew-due / expired / three unobservable fail-closed
cases / report-token mapping). `prodbox dev check` exit 0, unit 1854/1854, integration cli/env exit 0
(2026-07-19) for the previously landed increments. Focused exact-retention and substrate-aware plan
checks, the current unit total, build, docs, and diff evidence are recorded in the closure-history
entry in `DEVELOPMENT_PLAN/README.md`. No cluster is required for Sprint `2.35`; the live serving
proof is Sprint `5.22`.
**Docs updated**: `documents/engineering/acme_provider_guide.md`,
`documents/engineering/envoy_gateway_edge_doctrine.md`,
`documents/engineering/lifecycle_control_plane_architecture.md`, and the lifecycle/Vault/chart
doctrine surfaces that name the exact retained coordinate.

### Objective

Make certificate scope operator-configurable with illegal states unrepresentable on the
prodbox-managed side, derive the Certificate/retention projections from the one configured scope
set, and bind every explicit served edge host against it so the drift that produced the orphan
dashboard certificate cannot recur on the managed side.

### Deliverables

- Define the pure `CertScope` algebra in `src/Prodbox/Tls/CertScope.hs`: smart-constructed `Fqdn`,
  `CertScope` (`ScopeExact`/`ScopeWildcard DelegatedZone`), a canonical (deduped, ordered)
  `CertScopeSet`, total `covers`, the narrower-or-equal partial order `impliedBy`, `mkScopeSet`
  (rejecting wildcards anchored at an undeclared zone), and `bindListener` (rejecting an uncovered
  host). `DelegatedZone` is anchored in Tier-0 config — the home parent zone and
  `aws_substrate.subzone_name` — not the Public Suffix List. A wildcard never matches the apex or
  more than one label, so apex coverage requires an explicit exact scope.
- Add the Tier-0 scope-set config field plus fail-fast validation so a served hostname with no
  covering configured scope, and a wildcard anchored at a zone the operator has not delegated in
  config, are unrepresentable on the prodbox-managed side. The default configured scope set is
  today's exact served hosts, so there is no behavior change until an operator widens scope.
- Derive the keycloak public-edge Certificate `dnsNames`
  (`charts/keycloak/templates/gateway.yaml`) from the scope set, keyed on each substrate's served
  host. Each explicit listener/route/DNS served hostname is independently bound to and covered by
  that same set; wildcard SAN coverage does not synthesize an infinite listener or DNS inventory.
  Implemented as a values-injection
  projection (`Settings.certDnsNamesForServedHost` → `ChartPlatform.valuesForKeycloak`
  `gateway.certDnsNames` → template `range`) rather than a `const` generated section, because the
  dnsNames are substrate-dependent (home served host vs. AWS subzone); the
  `charts/gateway/templates/certificates.yaml` daemon mesh cert is per-node internal and is
  intentionally NOT scope-derived (the original "both sites via a generated section" wording was a
  spec imprecision).
- Re-key retention by a path-safe encoding of the canonical scope-set serialization, generalizing
  the historical substrate/FQDN coordinate to
  `public-edge-tls/<substrate>/<canonical-scope-key>`. Restore-before-issue matches only an identical
  canonical scope set: cert-manager treats any changed `Certificate.spec.dnsNames` set as a new
  issuance specification. `impliedBy` proves coverage/admission and never aliases retention keys.
- Replace the `validateSupportedPublicHost` hard-pinned single public-host literal in
  `src/Prodbox/Settings.hs` with scope-set coverage: a served hostname is admissible iff the
  configured scope set covers it.
- Add the `edge status` `certificate-renew-due`/`certificate-expired` rungs, observed fail-closed
  from cert-manager `status.renewalTime` (absent ⇒ `certificate-unobservable`) and `notAfter`, with
  no repo-side renewal-window recompute (which would drift from cert-manager's committed status).
  Renewal stays cert-manager's / ZeroSSL's alone; prodbox observes expiry and never drives ACME
  renewal from the daemon.

### Validation

1. Pure property tests prove the partial-order laws for `impliedBy`, the totality of `covers`,
   `mkScopeSet` rejection of undeclared-zone wildcards, and `bindListener` rejection of uncovered
   hosts.
2. Coverage / narrowing tables reproduce the boundary cases — a wildcard covers a single label but
   neither the apex nor a deeper `a.b.z`, and `*.a.z` is not `impliedBy` `*.z` — with generators
   spanning disjoint, non-covering, apex, multi-label, and single-label boundary scopes.
3. A conformance check proves the keycloak listener `dnsNames` values-injection equals the scope-set
   projection (an isolated `helm template` render plus `settings`-suite tests); the exact-retention
   table proves equal canonical sets reuse one coordinate while every distinct SAN set gets a
   distinct coordinate and first issuance. `impliedBy` tables remain coverage/admission proofs.
4. All of the above run pre-cluster; `prodbox dev check` and `prodbox test unit` pass.

### Remaining Work

- ✅ The pure `CertScope` algebra (`src/Prodbox/Tls/CertScope.hs`) and its property suite
  (`test/unit/CertScopeSuite.hs`) landed + validated 2026-07-18 (dev check exit 0).
- ✅ The Tier-0 scope-set config field (`DomainSection.cert_scopes`, default empty = today's exact
  served host) + fail-fast validation (`validateConfiguredCertScope` — undelegated-zone wildcard and
  uncovered served host rejected fail-closed) + the `validateSupportedPublicHost` pin replacement
  landed + validated 2026-07-19. Regenerated the Dhall schema (`config schema`) + binary-sibling
  `prodbox.dhall`, updated the config emitter and the `EnvSuite`/`CliSuite`/`Main.hs` fixtures, and
  added `settings`-suite validation tests (dev check exit 0, unit 1826/1826, integration cli/env
  exit 0).
- ✅ The derived public-edge `dnsNames` for `charts/keycloak/templates/gateway.yaml` landed
  (2026-07-19) as a **values-injection projection** of the configured scope set keyed on the served host
  (`Settings.certDnsNamesForServedHost` → `ChartPlatform.valuesForKeycloak` `gateway.certDnsNames` →
  template `range`), rather than a static generated block — because the dnsNames are substrate-dependent
  (home served host vs. AWS subzone) which a `const` generated section cannot capture. The
  `charts/gateway/templates/certificates.yaml` daemon mesh cert is per-node internal and is
  intentionally NOT derived from the public scope set. Proven behavior-identical for the default by an
  isolated `helm template` render and by three `settings`-suite tests (default served host, AWS-subzone
  served host, and a widened wildcard projection); dev check exit 0, unit 1847/1847.
- ✅ The retention re-key to an exact, path-safe `renderCertScopeSet` projection landed
  2026-07-20. `publicEdgeTlsRetentionKey` consumes `CertScopeSet`; deployment plans compile and
  expose the exact key; all retain/restore paths use it; delete planning preserves the selected
  substrate; and distinct SAN sets never alias through `impliedBy`. The exact single-host default
  remains byte-compatible with the historical object coordinate.
- ✅ The `edge status` `certificate-renew-due` / `certificate-expired` rungs landed (2026-07-19):
  `Prodbox.Host.classifyCertificateExpiry` is a pure fail-closed classifier over the already-fetched
  cert-manager `Certificate public-edge-tls` document (absent `notAfter`/`renewalTime` ⇒
  `certificate-unobservable`; `notAfter <= now` ⇒ `certificate-expired`, priority; `renewalTime <= now`
  ⇒ `certificate-renew-due`; else `certificate-current`), with no repo-side renewal-window recompute; the
  `edge status` report renders `CERTIFICATE_EXPIRY=<rung>`. Proven by 7 `host`-suite tests over fake
  Certificate JSON; dev check exit 0, unit 1854/1854. (Live observation of real cert-manager status is
  the Sprint `5.22` axis.)
- ✅ No code-owned work remains. Live serving proof against each explicitly bound substrate host,
  including inspection of the issued SAN set and exact restore/reissue behavior, is the independent
  deployment-qualification axis owned by Sprint `5.22` in
  [phase-5-canonical-test-suite.md](phase-5-canonical-test-suite.md) (Standards N/O).

## Documentation Requirements

**Engineering docs to create/update:**

- `documents/engineering/acme_provider_guide.md` - configurable certificate scope,
  coverage/admission semantics, and exact-SAN scope-change restore/reissue behavior.
- `documents/engineering/envoy_gateway_edge_doctrine.md` - explicit served-host binding to the
  configured `CertScopeSet`, exact retention, and the `edge status` `certificate-renew-due` /
  `certificate-expired` rungs.
- `documents/engineering/lifecycle_control_plane_architecture.md` - retention re-key to the
  canonical scope-set serialization and the closed certificate-material custody boundary.

**Product docs to create/update:**

- `README.md` - certificate-scope wording aligned with the configurable scope-set doctrine.

**Cross-references to add:**

- Link the serving-validation owner Sprint `5.22` in
  [phase-5-canonical-test-suite.md](phase-5-canonical-test-suite.md) and the deletion-ledger rows
  owned by this sprint in [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md).

## Sprint 2.36: Proof-Carrying Bootstrap Broker Shutdown [✅ Done]

**Status**: Done (validated 2026-07-27)
**Implementation**: `src/Prodbox/Bootstrap/Broker/Server.hs` and
`test/unit/BootstrapBrokerServerSafety.hs`
**Deployment qualification**: pending
**Independent Validation**: a deterministic finalizer-stall simulation and focused loopback
process suite prove that `Stopped` cannot be constructed before accept/worker joins, waiter
resolution, and an empty queue/active/idempotency postcondition. No cluster, AWS, or later phase.
**Docs to update**: `documents/engineering/lifecycle_control_plane_architecture.md`,
`documents/engineering/haskell_code_guide.md`, `documents/engineering/unit_testing_policy.md`

### Objective

Make the illegal state “externally stopped with internally live broker ownership” unrepresentable.
Timeout is a shutdown observation, not a child-termination proof.

### Deliverables

- Centralize terminal publication behind a private opaque `ShutdownComplete` witness.
- Forced drain atomically closes admission and resolves every running idempotency completion with a
  typed terminal shutdown reply before cancelling the structured child tree.
- Join the accept thread and every worker, then construct `Stopped` only from proof that queue,
  active ownership, and running idempotency entries are empty.
- A join deadline yields `ShutdownIncomplete` and retains `ForceDraining`; it never fills
  `handleDone` or publishes `Stopped`.
- Expose typed `BrokerShutdownIncomplete` observation for the Sprint `5.23` fixture-cleanup
  consumer.

### Validation

1. A deterministic hook holds a worker finalizer after force drain; `Stopped` remains impossible
   until the hook is released.
2. Owner and all coalesced replay waiters receive terminal results before worker cancellation.
3. Deadline-expiry tables produce `ShutdownIncomplete` with owned children still represented.
4. Releasing the hook joins every child and proves the exact empty postcondition before terminal
   publication.
5. Focused stress, the full unit suite, daemon lifecycle tests, and `prodbox dev check` pass.

### Remaining Work

- None on the Sprint `2.36` runtime-owned surface. Sprint `5.23` owns canonical-suite fixture
  teardown and run-final residue validation.

## Documentation Requirements

**Engineering docs to create/update:**

- `documents/engineering/lifecycle_control_plane_architecture.md` - proof-carrying broker shutdown.
- `documents/engineering/haskell_code_guide.md` - shared structured-concurrency terminal contract.
- `documents/engineering/unit_testing_policy.md` - deterministic finalizer-stall and cleanup proof.

**Product docs to create/update:**

- `README.md` - current Bootstrap Broker shutdown limitation and target invariant.

**Cross-references to add:**

- Link Sprint `5.23` as the canonical-suite consumer and record both obsolete timeout-discarding
  surfaces in [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md).

## Sprint 2.37: Non-Constructible Unacked-Suffix Retention and Failed-Checkpoint Recompaction [✅ Done]

**Status**: Done (2026-07-30) — Phase `2` own-surface reopen (Standard A) on the emitter-runtime
unbounded-memory class, exactly the reopen basis this phase already names (the July unbounded-memory
counterexample reopens the owned runtime surface). Additive and byte-compatible; no durable-format
change and no runtime selector.
**Blocked by**: none (own-surface reopen; the code-owned surface is validated without a later phase or
live infra).
**Live-proof**: pending — a healthy live ≥2.4h `JournalLeaseEmitter` run holding a bounded resident set
under a stalled-signer/unreachable-peer fault is the non-blocking Standard-O axis (the currently deployed
`LegacyModelBEmitter` OOM is baseline residue scheduled for deletion, not extension — see below).
**Deployment qualification**: pending — this hardens the cutover-target emitter against the
retained-assertion leak class but does not by itself qualify the composed revision; the live leak-free
aggregate remains the Standard-P axis.
**Independent Validation**: pure kernel decide/evolve fixtures over an in-memory interpreter, with no
cluster, Vault, object store, or later phase: an over-ceiling suffix is non-constructible
(`appendUnacked` fails closed at the ceiling) and a `CheckpointFailed` outcome re-emits the exact pending
compaction so a stalled signer cannot wedge the suffix. `prodbox dev check` exit 0 (warning-clean
`-Werror`, fourmolu, HLint, conformance); Sprint 2.32 kernel/actor suite 121/121; Sprint 2.31 bounded
gateway core 65/65.
**Docs to update**: `documents/engineering/distributed_gateway_architecture.md`,
`documents/engineering/chaos_hardening_doctrine.md`,
`documents/engineering/resource_scaling_doctrine.md`
**Implementation**: `src/Prodbox/Gateway/Emitter/Kernel.hs` (`BoundedUnackedSuffix` and the fail-closed `appendUnacked`), `src/Prodbox/Gateway/Daemon.hs`, `src/Prodbox/TestValidation.hs`. Back-filled by Sprint `0.27` from the paths this sprint's own Deliverables name.

### Objective

Make the Sprint `2.32` `emitterUnacked` retention bound *structural* rather than checkpoint-fold-
dependent, and close the stalled-signer liveness wedge at its root, so the single-writer
`JournalLeaseEmitter` (the cutover target) cannot exhibit the unbounded retained-assertion growth that
was reproduced live on 2026-07-29 as an `LegacyModelBEmitter` OOM cycle (gateway-node-b restarting on
its ~460 MiB cgroup limit). Sprint `2.32` correction (3) declared this bound at the durable projection
boundary (`ProjectionMaximumRetainedAssertions` in `validateDurableProjection`) and claimed it enforced
by a "size-triggered checkpoint fold"; the live counterexample proved that claim insufficient because
the fold's compaction depends on the signer succeeding and there was no hard ceiling on the live suffix.

### Deliverables

- `Gateway/Emitter/Kernel.hs` introduces `BoundedUnackedSuffix`: a hidden-constructor contiguous suffix
  carrying its own hard ceiling, whose *only* growth operation `appendUnacked` fails closed at the
  ceiling (`Left (UnackedSuffixFull n)`), so an over-retention state has no representation. The ceiling
  is the emitter's already-existing `projectionMaximumRetainedAssertions` durable bound; the separate
  `emitterUnackedThreshold` remains only the compaction trigger (threshold ≤ ceiling). The remaining
  vocabulary is total and length-safe: `emptyUnackedSuffix`, `dropUnackedPrefix` (compaction),
  `mapUnackedSuffix` (peer acknowledgement, length-preserving), `restoreUnackedSuffix` (re-check a
  durable list against the ceiling), plus the `unackedSuffixList` / `unackedSuffixLength` /
  `unackedSuffixMaximum` projections.
- `finalize` grows the suffix through `appendUnacked` and, at the ceiling, refuses the commit with the
  new `RejectUnackedSuffixFull` reason — the in-flight work stays represented for recovery rather than
  the heap climbing indefinitely.
- Root-cause liveness fix in `stepCheckpointResolved`: a `CheckpointFailed` outcome now re-emits the
  exact `EffCheckpointCompaction incarnation deadline candidate` so the signer retries the pending
  candidate instead of leaving it un-driven — the path by which the suffix previously grew without bound
  behind a stalled signer. The pending candidate is deliberately kept so the identical checkpoint is
  retried, and the retained suffix stays bounded regardless through the fail-closed ceiling.
- `restoreDurableEmitterState` reconstructs the suffix through `restoreUnackedSuffix`, re-checking the
  already-validated durable list against the ceiling (defense in depth) and mapping an over-ceiling list
  to the pre-existing `DurableProjectionRetainedAssertionCountExceeded`. The durable projection field
  `durableProjectionUnacked :: [UnackedAssertion]` is unchanged, so retained journals round-trip
  byte-for-byte with no migration.
- `Gateway/Daemon.hs` threads the emitter's `projectionMaximumRetainedAssertions` bound into every
  `mkEmitterState*`/`restoreDurableEmitterState` call site; the `gateway-partition` native validation
  path (`TestValidation.hs`) is updated for the same signatures.

### Validation

1. `appendUnacked` fails closed at the ceiling and no larger suffix is constructible (kernel fixture).
2. A `CheckpointFailed` outcome re-emits the exact pending compaction and keeps the candidate; the
   suffix cannot wedge (kernel fixture).
3. Byte-compatibility: the durable projection format is unchanged; existing restore/migration/
   acknowledgement/checkpoint fixtures pass unmodified through the suffix projections.
4. `prodbox dev check` and the emitter suites pass (see Independent Validation).

### Remaining Work

- None on the code-owned kernel surface. The live long-run leak-free proof is the non-blocking
  Standard-O axis; deployment qualification of the composed revision remains the Standard-P axis owned
  by Sprint `8.12`. The production entrypoint stays `LegacyModelBEmitter` until qualification permits
  cutover (Standard P); this sprint does not delete the legacy continuity path.

## Sprint 2.44: A Sampler That Claimed To Have Observed Stability ✅

**Status**: ✅ **Done (2026-08-12)** — Phase `2` own-surface reopen (Standard A) on the gateway
runtime-stability surface this phase owns. Registered by Sprint `5.33`, which found it while
removing `gateway-partition` and deliberately did not fold it in: it is a fold defect on this
phase's runtime surface rather than suite content, and Standard M keeps those ownerships apart.
**Implementation**: `src/Prodbox/TestValidation.hs` (`GatewayRuntimeSampleOutcome`,
`gatewayRuntimeSampleOutcome`, `gatewayRuntimeSampleOutcomeExit`, `gatewayRuntimeSampleExit`),
`test/unit/Main.hs`.
**Blocked by**: none.
**Deployment qualification**: pending (not invalidated) — no process topology, capability wiring,
deadline algebra, persistence, or cleanup surface moves. The sampler's exit codes are unchanged; what
changes is that two of them are now distinguishable in the transcript.
**Independent Validation**: pure unit cases over the extracted decision; no cluster, no AWS, no later
phase. `prodbox dev check` exit 0; `prodbox test unit` exit 0.
**Docs updated**: none under `documents/` — no governed document describes this fold, and the
sampler/gate split it records is stated in the function's own Haddock rather than duplicated.

### Objective

Close the row recording that `gatewayRuntimeSampleExit` returns success when stability was not
observed, while `runGatewayRuntimeStabilityGateInCurrentContext` ten lines above honours the same
`NotStableYet` constructor by retrying and then failing.

### The row described the defect correctly and implied the wrong remedy

Read literally — "returns success when stability was not observed" — the fix is to make it fail. That
would be wrong, and measuring the caller is what shows it:
`recordGatewayRuntimeStabilitySample` is invoked at **ten** points in `src/Prodbox/TestRunner.hs`,
interleaved between suite phases to feed the recorder. It is a **sampler**, not a gate. A run that
aborted the first time the runtime had not yet converged would never reach the gate that owns the
verdict.

So the two folds are *right to disagree* about `NotStableYet`. What was wrong is that the sampler
disagreed **silently**: `StableObserved` and `NotStableYet` both returned a bare `ExitSuccess` with no
output, so a sample that observed non-stability was indistinguishable from one that observed
stability — in the exit code and in the transcript alike. The ADT's third value was discarded rather
than recorded, which is the defect; continuing is not.

### Deliverables

- **The decision is a pure total function.** `gatewayRuntimeSampleOutcome` maps the report's four
  constructors onto a four-constructor `GatewayRuntimeSampleOutcome`, and
  `gatewayRuntimeSampleOutcomeExit` lowers that to an `ExitCode`. This follows the repository's
  [pure-by-default interpreter boundary](../documents/engineering/pure_fp_standards.md#11-pure-by-default)
  and makes the
  distinction testable without capturing a stream.
- **Each arm says what it saw.** The not-yet-stable arm names the observed and required sample
  counts, states that the run continues *because this is a sampler and the gate owns the verdict*,
  and says in terms that it **is not an observation of stability**.
- **The bound is asserted, not described.** A unit case pins that the sampler exits 0 on
  not-yet-stable where the gate fails, so the deliberate disagreement is a checked property rather
  than a comment.

### Validation

1. `gatewayRuntimeSampleOutcome` maps `StableObserved` and `NotStableYet` to distinct outcomes — the
   collapse this sprint removes. ✅
2. All four outcomes are pairwise distinct, and their exits are
   `[ExitSuccess, ExitSuccess, ExitFailure 1, ExitFailure 1]`. ✅
3. `prodbox dev check` exit 0; `prodbox test unit` exit 0 at main Hspec **3398/3398**;
   `prodbox test integration cli` / `env` exit 0. ✅

### Remaining Work

None. **The bound stated plainly**: this sampler still exits 0 when stability was not observed, and
that is deliberate. What it no longer does is claim to have observed stability. A reader of the
transcript can now tell the two apart, which is what the row's "honoured on one path and discarded on
the other" was really about.


## Documentation Requirements

**Engineering docs to create/update:**

- `documents/engineering/distributed_gateway_architecture.md` - non-constructible retained-assertion
  suffix and failed-checkpoint recompaction as emitter runtime invariants.
- `documents/engineering/chaos_hardening_doctrine.md` - stalled-signer / unreachable-peer fault and the
  bounded-retention proven property.
- `documents/engineering/resource_scaling_doctrine.md` - the emitter retained-assertion ceiling as a
  structural (non-authored) memory bound.

**Product docs to create/update:**

- None.

**Cross-references to add:**

- Link the bounded-retention invariant to Sprint `2.32`'s emitter kernel and to the Deployment
  Qualification ledger's outstanding live leak-free axis in [README.md](README.md).

## Sprint 2.39: Restore the Broker's Constant-Time Readiness Contract ✅

**Status**: Done (2026-08-07) on this sprint's code-owned surface. Live-surfaced 2026-08-04 on a
cold home bring-up; this is a Phase-2-owned production defect on the Bootstrap Broker runtime, not a
harness or environment problem, and it blocked **every** home-substrate bring-up.

**Status correction (Sprint `0.21`, 2026-08-05).** This block previously read `📋 Planned` with a
`Remaining Work` section stating *"no fix has been attempted"*. That was false at the time it was
read: `src/Prodbox/Bootstrap/Broker/Readiness.hs` and the reworked
`src/Prodbox/Bootstrap/Broker/ProductionEngine.hs` had already moved `/readyz` to a cached
projection with a background observer. Standard C requires status to describe reality, so the
marker is corrected to `🔄 Active` and `Remaining Work` now names what is genuinely outstanding.
Two of the three deliverables have landed; the third has not, and the landed half rests on an
unsound constant (Sprint `2.40`).

**Blocked by**: none. The defect and its fix are code-owned; the reproducer below needs only a
running cluster.
**Deployment qualification**: pending — readiness semantics are a Standard-P surface. Both rows are
already `pending`; this sprint is a prerequisite for any home qualification run, because
`prodbox cluster reconcile` cannot converge until it lands.
**Implementation**: `src/Prodbox/Bootstrap/Broker/Readiness.hs`, `src/Prodbox/Bootstrap/Broker/ProductionEngine.hs`, `src/Prodbox/CheckCode.hs` (`checkBrokerReadinessProjection`), `charts/bootstrap-broker/values.yaml`. Back-filled by Sprint `0.27` from the paths this sprint's own body names.
**Docs updated**: `documents/engineering/code_quality.md`, which names this sprint for the `checkBrokerReadinessProjection` conformance gate. Back-filled by Sprint `0.27` from the governed document that cites it.

### Objective

`charts/bootstrap-broker/values.yaml` (probeTiming) states the invariant plainly:

> The broker's liveness/readiness endpoints are constant-time route projections (Sprint `2.34` route
> registry); deep capability observations execute through the broker's own client, **never in a
> kubelet probe.**

The runtime does not honour it. `productionReady`
(`src/Prodbox/Bootstrap/Broker/ProductionEngine.hs`) performs, inline in the `/readyz` request path:

- `bootstrapStoreReady` — a MinIO `listKeys` plus a generation-object read;
- `Vault.vaultSealStatus` — an HTTP call to the Vault Service;
- `kubernetesObserveBootstrapLease` — a Kubernetes API read with a **5-second** deadline;
- `kubernetesObserveControllerImageDigest` — a second Kubernetes API read with a **5-second**
  deadline.

These are exactly the "deep capability observations" the invariant forbids there. The probe budget is
calibrated for the projection the comment describes (`timeoutSeconds: 1`, `--max-time 1`), so the
endpoint cannot meet it.

**Measured on the live home cluster (2026-08-04), same pod:**

| Endpoint | Latency | Result |
|----------|---------|--------|
| `/healthz` | 0.19 ms | `{"healthy":true}` — a true constant-time projection |
| `/readyz` | **5.003 s** | `{"ready":false}` — a timeout, 5× the probe budget |

The consequence is total: the readiness probe can never pass, the Deployment never reports available,
`helm upgrade` fails with `Progress deadline exceeded`, and `prodbox cluster reconcile` exits 1
before Vault is ever initialized. Two consecutive cold reconciles failed identically.

A second, independent defect compounds it. In the same pod, the projected ServiceAccount token was
rejected by the API server with **HTTP 401 in 2.0 s**, while a sibling pod (`prodbox/minio-0`)
authenticated normally (**HTTP 403 in 9 ms** — authenticated, merely unauthorized). Token
authentication is therefore healthy cluster-wide and specifically broken for the broker Pod, so both
Kubernetes observations fail regardless of the deadline. The likely mechanism is the failed-release
uninstall/reinstall cycle recreating the `prodbox-bootstrap-broker` ServiceAccount with a new UID
while a Pod holding a token bound to the previous UID survives; that must be confirmed rather than
assumed.

Note also that `Left _ -> pure (Left BootstrapStoreUnavailable)` in `ProductionStore.hs` discarded the
underlying store error, so the first two hours of this failure reported only an opaque constructor.
A diagnostic log at that collapse point landed with this investigation (wire vocabulary unchanged);
that is a prerequisite for anyone debugging the store half.

### Deliverables

- `/readyz` becomes a projection over cached, boundary-owned facts — the shape Sprint `2.34` already
  established for the gateway — rather than a request-time fan-out across MinIO, Vault, and two
  Kubernetes reads. A background observer refreshes the facts; the endpoint reads the latch.
- The probe budget and the readiness computation are related by construction, so a probe budget
  smaller than the work behind the endpoint is unrepresentable rather than a silent 5× mismatch.
- A conformance gate asserting `/readyz` performs no boundary I/O in its request path, so the
  invariant the chart comment asserts is enforced rather than described.
- The 401 is root-caused and fixed, with the disposition recorded: a rejected token must not be
  indistinguishable from an unready dependency.

### Validation

1. Reproducer: on a cold home cluster, `curl --max-time 1 http://127.0.0.1:8600/readyz` inside the
   broker Pod succeeds, and `/readyz` latency is within the same order as `/healthz`.
2. `prodbox cluster reconcile` converges to exit 0 from the half-built state.
3. The conformance gate fails if a boundary call is reintroduced into the readiness path.

### Remaining Work

Rewritten 2026-08-05 (Sprint `0.21`) to describe the tree as it stands.

**Landed.** `/readyz` is a constant-time projection over boundary-owned cached facts
(`src/Prodbox/Bootstrap/Broker/Readiness.hs`, `computeBrokerReadiness`), refreshed by a background
observer; no boundary call remains on the request path. The dependency observation is four-valued,
with an **absorbing** identity-rejection constructor, so the broker-Pod-only ServiceAccount-token
401 can no longer read as "not up yet" — that is the *Distinguishability* class of
[chaos_hardening_doctrine.md § 21](../documents/engineering/chaos_hardening_doctrine.md), and it is
what makes the second half of the original defect unrepresentable rather than merely handled.

**✅ Landed — deliverable 3, the conformance gate.** `checkBrokerReadinessProjection` /
`brokerReadinessProjectionViolations` are in `src/Prodbox/CheckCode.hs`, wired into the same
conformance sequence as the readiness-observation and gateway-probe scans. The comment in
`ProductionEngine.hs` that referred to a `broker-readiness-projection` gate now refers to something
that exists.

It makes two **structural** claims rather than scanning for known-bad calls:

- `Prodbox.Bootstrap.Broker.Readiness` may import only pure modules (`Data.*`, `Numeric.*`,
  `GHC.Generics`), so no boundary is in scope where the fold is defined;
- `productionReady`'s body draws from an exact token allowlist — the monotonic clock read, the
  latched-record read, and the pure fold — so a **new** call fails the gate rather than only a
  previously-seen one. A forbidden-substring list would need extending every time somebody invents
  another way to reach a backend; an allowlist does not. A deleted `productionReady` is a finding
  too, so the gate cannot pass vacuously.

**Open — the staleness bound is unsound.** Split out as Sprint `2.40`; the landed projection is not
correct until it lands. That is a separate sprint's surface, not this one's, and this sprint does not
claim it.

**🧪 Live-proof: pending.** Validation items 1 and 2 (cold-cluster `curl --max-time 1` inside the
broker Pod, and `cluster reconcile` converging to exit 0 from the half-built state) are Standard-O
live-infra proofs and remain unrun. Per [Standard O](development_plan_standards.md#o-code-local-completion-vs-live-infra-proof)
they do not prevent `Done` on the code-owned surface, and the sprint is not claiming the home
bring-up is unblocked — only that the request path is now constant-time by construction and stays
that way.

**Code-owned evidence**: `prodbox-unit -p "Sprint 2.39"` 5/5, including a case proving a boundary
brought into import scope is refused, a case proving an unrecognised new call on the request path is
refused, and a case proving a deleted request path is a finding rather than a pass. `dev check`
exit 0.

## Sprint 2.40: Derive the Broker's Readiness Staleness Bound ✅

**Status**: Done (2026-08-07) — Phase `2` own-surface work on the Bootstrap Broker readiness
projection Sprint `2.39` introduced.
**Implementation**: `src/Prodbox/Bootstrap/Broker/Readiness.hs` (`ObservationSchedule`,
`ObservationScheduleError`, `mkObservationSchedule`, `brokerReadinessSchedule`;
`computeBrokerReadiness` now takes the schedule), `src/Prodbox/Bootstrap/Broker/ProductionEngine.hs`,
`src/Prodbox/Bootstrap/Broker.hs`.
**Blocked by**: none. Sprint `2.39`'s projection is already in the tree; this corrects a constant
inside it.
**Deployment qualification**: pending — readiness semantics are a Standard-P surface, and both rows
are already `pending`.
**Independent Validation**: pure, injected-clock, no live substrate — a focused unit case pinning
`stalenessBound >= 2 * (observerPeriod + observationBudget)` for the shipped schedule, plus a
mutation exercise restoring the current free constants and observing the case fail.
**Docs to update**: `documents/engineering/bootstrap_readiness_doctrine.md`

### Objective

Sprint `2.39`'s projection fails closed when its cached record is older than
`brokerReadinessObservationBoundMicros`. That bound is authored as `3 * observerPeriod` = 15 s,
independently of the per-pass budget. The observer's actual inter-stamp interval is
`observerPeriod + passDuration`, and `observedAt` is stamped **after** the pass, so the interval
includes the whole pass. With a 5 s period and a 5 s budget the bound must be at least
`2 * (5 + 5)` = 20 s; it is 15 s.

The consequence is not a slow failure, it is a self-inflicted one: a broker whose dependencies are
all `Ready` projects `Starting` for most of every cycle, and `failureThreshold: 6` at
`periodSeconds: 10` removes the Pod after 60 s. A healthy system evicts itself because two
constants were authored separately.

This is the *Containment* class of
[chaos_hardening_doctrine.md § 21](../documents/engineering/chaos_hardening_doctrine.md): bounds are
computed, never authored.

### Deliverables

- ✅ An `ObservationSchedule` with a hidden constructor whose single smart constructor **derives**
  the staleness bound as `2 * (period + budget)`, so a bound the observer cannot meet is not
  constructible. The reasoning is in the type's own documentation rather than in a commit message:
  `observedAt` is stamped *after* a pass, so the inter-stamp interval is `period + passDuration`,
  and tolerating one missed pass doubles it.
- ✅ `computeBrokerReadiness` takes the schedule rather than reading free top-level constants, so the
  bound the projection enforces is the one the observer that filled the record was built with.
  Reading a free constant is exactly how the two drifted apart.
- ✅ The three independently-authored constants are replaced by that one value:
  `brokerReadinessObserverPeriodMicros` and `brokerReadinessObservationBoundMicros` in
  `Broker/Readiness.hs`, and `readinessObservationBudgetMicros` in `Broker/ProductionEngine.hs`. The
  observer loop in `Broker.hs` and the two observation deadlines in `ProductionEngine.hs` now read
  the schedule.

### Validation

1. ✅ `prodbox-unit -p "Sprint 2.40"` — 3/3, including `stalenessBound >= 2 * (period + budget)` for
   the shipped schedule, and the concrete consequence: a record aged one full inter-stamp interval
   (10 s) still projects `Ready`, which is precisely where the superseded 15 s bound began evicting
   a healthy broker.
2. ✅ The mutation exercise: restoring `3 * (5 * 1000 * 1000)` as the bound fails
   *derives a bound the observer can actually meet*, and the source restored byte-exactly
   (`sha256sum -c`: `OK`).
3. ✅ `mkObservationSchedule` returns `Left ObservationPeriodZero` for a zero period and
   `Left ObservationBudgetZero` for a zero budget — refused rather than normalised, because a zero
   period is a spin and a zero budget is a pass that cannot complete.
4. ✅ `prodbox dev check` exit 0.

### Remaining Work

None. Note what this does and does not settle: the shipped bound is now 20 s rather than 15 s and is
derived, so the self-eviction arithmetic is corrected at the source. Whether a live broker converges
under it is the Sprint `2.39` reproducer's business, and that remains 🧪 Standard-O.

## Sprint 2.41: One Emitter Authority Value and a Supervised Worker Roster ✅

**Status**: Done (2026-08-07) — Phase `2` own-surface work on the gateway daemon runtime this phase
owns.
**Implementation**: `src/Prodbox/Gateway/Daemon.hs` (`EmitterAuthority` replacing `envContinuity` /
`envEmitterRuntime` / `envEmitterAuthorityStatus`; `daemonWorkerNames`, `daemonWorkerAction`,
`withSupervisedWorkers`), `src/Prodbox/Gateway/Readiness.hs` (`WorkerState`, `WorkerRoster`,
`workerRosterLive`, `workerRosterStalled`; `WorkersStatus` deleted; `computeReadiness` folds the
roster), `src/Prodbox/CheckCode.hs` (`checkSupervisedWorkers`).
**Blocked by**: none.
**Deployment qualification**: pending — process topology and readiness semantics are Standard-P
surfaces; both rows are already `pending`. This sprint does not perform the emitter cutover, so it
neither advances nor invalidates qualification.
**Independent Validation**: pure fold plus fake-driven daemon fixtures, no live substrate — the
readiness fold rejects `Ready` when the authority runtime is absent or a roster worker has exited,
proven by a mutation exercise that reintroduces the split state and observes the case fail.
**Docs to update**: `documents/engineering/distributed_gateway_architecture.md`

### Objective

Two defects with one shape: a fact and the runtime it asserts live in separate mutable cells that
can disagree.

`Prodbox.Gateway.Daemon` keeps emitter readiness in `envEmitterAuthorityStatus` and the runtime it
asserts in `envContinuity`. Five sites clear `envContinuity` and touch readiness on none of them —
deliberately, under a comment describing the readiness cell as a monotone latch. `Ready` while
`envContinuity == Nothing` is therefore reachable in production, and it is reachable on the
**deployed** path: `runGatewayDaemon` selects `LegacyModelBEmitter`, whose authority arm is a bare
`readTVar`, while the lease-re-checking arm belongs to the target topology.

Separately, `WorkersStatus` is a monotone flag written before any worker exists, so a worker that
dies never un-readies the Pod, and eight long-lived children are spawned without linking their
handles.

Both are the *Staleness* and *Scope* classes of
[chaos_hardening_doctrine.md § 21](../documents/engineering/chaos_hardening_doctrine.md). The fix
for the first is deletion, not synchronisation: if two cells can disagree, keep one.

### Deliverables

- ✅ One `EmitterAuthority` value replacing all three cells, so clearing the runtime *is* clearing
  readiness. `currentEmitterReadinessAuthority` is now topology-free — it folds the authority value
  rather than branching on `envEmitterTopology`, so the legacy arm can no longer be the one that
  forgets. It used to be a bare `readTVar` of a readiness cell that the five continuity-clearing
  sites deliberately left alone, under a comment calling it a monotone latch, which is how `Ready`
  with no runtime became reachable on the **deployed** path.

  **One distinction was deliberately kept rather than collapsed**, and the reason is worth
  recording: the journal topology genuinely needs "runtime installed, not currently authoritative"
  while recovery is outstanding. Collapsing readiness into runtime *presence* would have broken
  that, so `EmitterAuthorityRecovering` is its own constructor. The type keeps the distinction the
  runtime actually has and removes the one nothing needed.
- ✅ A `WorkerRoster` with `withSupervisedWorkers` as the only way to run a long-lived worker: it
  links the `Async` (so a worker's exception reaches the supervisor instead of a discarded handle),
  stamps a heartbeat on a timer, and records exit through `finally` — on every path, including an
  exception. `daemonWorkerNames` is the single list from which both the roster and the spawn set are
  built, so a worker cannot exist without a readiness entry.
- ✅ `WorkersStatus` deleted. The readiness fold consumes the roster against a heartbeat bound
  derived from the beat interval (the Sprint `2.40` rule applied again), so a worker that exits
  **or** stops beating removes the Pod from ready endpoints. The flag could express neither: it was
  written once, at `daemonWorkers` entry, before any worker existed.

### Validation

1. ✅ `prodbox-unit -p "Sprint 2.41"` — 6/6, plus the migrated readiness suite; full unit 3191/3191.
2. ✅ The readiness fold returns `Starting`, not `Ready`, when no authority runtime is held — and the
   type no longer permits the readiness value to be constructed separately from the runtime, so the
   case is closed by construction rather than by the assertion.
3. ✅ A worker recorded as exited holds the fold at `Starting`, as does one whose heartbeat has aged
   past the bound. The mutation exercise — replacing the roster fold with a monotone
   "any worker was ever registered" test, which is what the deleted flag amounted to — fails four
   cases (*folds the full input table*, *never admits before the workers have started*, *has exactly
   one Ready cell*, and the Sprint 2.41 case), and the source restored byte-exactly
   (`sha256sum -c`: `OK`).
4. ✅ Raw `withAsync` is not in scope in `src/Prodbox/Gateway/Daemon.hs`; `checkSupervisedWorkers`
   fails the build if it returns, and also if `withSupervisedWorkers` itself disappears so the gate
   cannot pass vacuously.
5. ✅ `prodbox dev check` exit 0.

### Remaining Work

None on this sprint's surface.

**🧪 Live-proof: pending, and load-bearing here.** This changes readiness on the **deployed**
`LegacyModelBEmitter` path: a gateway whose continuity runtime is cleared now un-readies, where
before it stayed `Ready`. That is the defect being fixed, and it is also a behaviour change no fake
fixture can qualify — a live gateway that clears its continuity runtime transiently will now leave
ready endpoints where it previously did not. The fake-driven fold proves the projection; only a live
run proves the operational consequence.

## Sprint 2.38: Reachable Shutdown Postcondition for the Bootstrap Broker [✅ Done]

**Status**: Done (2026-08-04) — Phase `2` own-surface reopen (Standard A/N) on the Bootstrap Broker
runtime this phase owns, correcting the Sprint `2.36` shutdown postcondition from an unreachable
condition to the one it was meant to express.
**Implementation**: `src/Prodbox/Bootstrap/Broker/Server.hs` (`proveShutdownComplete`,
`runningEntryCount`, `BrokerServerSnapshot.snapshotRunningIdempotencyEntries`),
`test/unit/BootstrapBrokerServerSafety.hs`, `test/unit/BootstrapBrokerRuntime.hs`
**Blocked by**: none (own-surface reopen; validated without a later phase or live infrastructure).
**Deployment qualification**: pending — this **does** touch a Standard-P surface (lifecycle
orchestration: broker shutdown). Both substrate rows are already `pending`, so nothing is
invalidated, but the next qualification run must exercise the post-`2.38` shutdown path.
**Independent Validation**: real-loopback broker suite, no live substrate or later phase —
`prodbox test unit -p "Sprint 2.33 Bootstrap Broker server"` 7/7 and the broader
`-p "Bootstrap Broker"` 114/114, plus a reproducer exercise: restoring the pre-fix postcondition
wedges the new graceful-drain case at `BrokerForceDraining`, and the source restores byte-exactly.
`prodbox dev check` exit 0.
**Docs to update**: none

### Objective

Sprint `2.36` made terminal shutdown proof-carrying: `BrokerStopped` may be published only through an
exact postcondition witness. The witness it shipped asked for `queued == 0 && active == 0 &&
Map.null entries` — an **empty** idempotency map.

An empty map is not reachable in normal operation. A completed request deliberately retains its
idempotency binding so a later replay can be answered from cache, and completed bindings are evicted
only under capacity pressure. So after any successful request, the manager's fully-graceful branch
retried forever on a condition that could no longer become true.

The failure mode is worse than a slow shutdown. `proveShutdownComplete` reads only the queue, the
active count, and the entry map — never the phase — so a subsequent `forceBrokerDrain`, which writes
the phase, could not wake the retrying transaction. The manager thread stayed blocked, the completion
cell was never filled, and `waitBrokerServer` blocked with it. A graceful broker shutdown after any
completed request wedged permanently, with no escalation path.

This was invisible because the Sprint `5.23` fixture cleanup discarded both its timeout and the
`BrokerShutdownIncomplete` witness (see Sprint `5.27`, which fixes that and surfaced this). Every
affected test leaked a permanently blocked manager thread rather than failing.

### Deliverables

- `proveShutdownComplete` requires no **running** entry rather than an empty map. A completed binding
  is inert replay cache, not a live waiter, so this is the property Sprint `2.36` intended: nothing
  queued, nothing active, no unresolved completion cell. The forced path is unchanged — it already
  clears the whole map through `resolveRunningWaitersForShutdown` before proving.
- This restores agreement with `Prodbox.Bootstrap.Broker.ShutdownModel`, whose residue oracle counts
  `WaiterRunning` rather than all waiter cells. The model and the server had disagreed, and the model
  was right.
- `BrokerServerSnapshot` gains `snapshotRunningIdempotencyEntries` so the postcondition's actual term
  is observable, and the Sprint `5.27` residue oracle can express the model's triple exactly instead
  of approximating the running count with the total.
- A regression case pins the counterexample: a completed request, then a graceful drain, must reach
  `BrokerStopped` with the completed binding still retained.

### Validation

1. `prodbox test unit -p "Sprint 2.33 Bootstrap Broker server"` 7/7, including the new
   graceful-drain-after-completion case.
2. Reproducer: restoring `Map.null entries` wedges that case at `BrokerForceDraining` with **zero**
   running waiters — proving the demand was unreachable rather than genuinely unsatisfied.
3. The Sprint `2.36` property is preserved: the finalizer-stall case still refuses to publish
   `BrokerStopped` while a cancelled worker finalizer is stalled.
4. `prodbox dev check` exit 0.

### Remaining Work

None.

## Sprint 2.42: The Broker's Readiness Reason Survives Its Transport ✅

**Status**: Done — Phase `2` own-surface reopen (Standard A/N) on the Bootstrap Broker readiness
contract this phase already owns through Sprints `2.39` and `2.40`. Registered by the live
investigation of a Phase-`3` chart defect: the chart was the cause, and the broker's own reporting
is why it took eight runs and roughly four hours to find.
**Implementation**: `src/Prodbox/Bootstrap/Broker/KubernetesWorker.hs` (the discarded transport
error), reaching the operator through `src/Prodbox/Bootstrap/Broker/ProductionEngine.hs` and
`src/Prodbox/Bootstrap/Broker/Readiness.hs`.
**Blocked by**: none.
**Deployment qualification**: pending — the change is to the *reason text* carried in an existing
readiness projection, not to the readiness verdict, the probe wiring, or any rendered manifest. None
of Standard P's enumerated surfaces moves; both substrate rows stay `pending`.
**Independent Validation**: pure and local — a fake Kubernetes boundary returning each transport
failure constructor is asserted to produce a distinct, non-empty reason in the `/readyz` body, with
a negative case proving a bare "unavailable" string can no longer be produced. No live
infrastructure.
**Docs to update**: none — the rule is
[chaos_hardening_doctrine.md § 23](../documents/engineering/chaos_hardening_doctrine.md) corollary 2,
already authored by Sprint `0.25`.

### Objective

`kubernetesObserveBootstrapLease` discards a typed transport failure:

```haskell
Left _ -> pure (BootstrapLeaseUnobservable "Kubernetes Lease observation unavailable")
```

A NetworkPolicy was dropping the broker's packets to the Kubernetes API. What the operator saw for
thirty minutes was `dependency-unavailable: bootstrap-lease: Kubernetes Lease observation
unavailable` — a sentence that names neither the endpoint dialled, nor the failure mode, nor the
fact that a packet was dropped rather than a request refused. `/healthz` stayed 200 the whole time,
so the process was visibly alive and inexplicably not ready.

This is § 23 corollary 2 — *do not convert a typed failure into an untyped one* — at the broker's
Kubernetes boundary. The reason was a value and it was thrown away. Distinguishing the cases matters
because they imply different operator actions: a dropped packet is a policy or routing defect, a
`403` is RBAC, a `404` is a missing object.
[pure_fp_standards.md § 2.3](../documents/engineering/pure_fp_standards.md) states the same rule
from the decode side: invalid, corrupt, missing, and unobservable are distinct when they imply
different decisions.

### Deliverables

- ✅ **The transport detail reaches the readiness body.** `Left detail` is carried into
  `BootstrapLeaseUnobservable` rather than discarded, at the lease site and at the symmetric worker
  site. All six discarding sites in `productionKubernetesWorkerBoundary` now compose through
  `unobservableReason` — the two `BootstrapLeaseUnobservable` sites (observation and write) and the
  four `SecretWorker*Unobservable` sites (attestation, exit, deletion, absence).
- ✅ **The detail is actually a detail.** `requestKubernetes` classifies its caught exception rather
  than collapsing it, so the reason gains information and not merely a prefix.
- ✅ **Classify, never `show`.** `kubernetesTransportFailureLabel` pattern-matches every
  `HttpExceptionContent` constructor of `http-client` 0.7.19 plus `InvalidUrlException` onto a
  closed set of fixed labels. The `Request` is matched as `_` and never inspected, and no
  constructor argument is interpolated — `InvalidRequestHeader` can carry the `Authorization`
  header itself, and the two proxy constructors can carry proxy credentials. The match carries no
  wildcard arm, so a new upstream constructor is a compile error rather than a silent collapse.

### Validation

1. ✅ Each transport failure constructor produces a distinct reason, asserted by exact string —
   21 constructor fixtures in `test/unit/BootstrapBrokerProductionBoundary.hs`, plus a mutual
   distinctness assertion and a non-empty assertion over the same set.
2. ✅ A negative case: no input produces the bare `"Kubernetes Lease observation unavailable"` with
   no detail appended; every composed reason is asserted to carry the site phrase *and* a suffix.
3. ✅ A credential-safety case: a bearer token planted in the four credential-carrying constructors
   appears in no rendered reason, and neither does `Authorization` nor `Bearer`.
4. ✅ `prodbox dev check` exit 0; `prodbox test unit` exit 0 (3319 + 27 + 33 + 27 tests).

### Remaining Work

None. Registered rather than absorbed into Sprint `3.34`. That sprint's surface is the chart
platform and the chart lint; this one is broker runtime, which Phase `2` owns. The two share a live
failure and nothing else — and the division is worth stating precisely, because the chart defect
caused the outage while this defect caused its cost.

**The honest bound on this sprint.** It shortens the distance between a transport failure and its
diagnosis; it does not prevent one. The live outage that registered it is Sprint `3.34`'s to fix,
and a reader should not read `2.42` as having addressed the cause. What it changes is that the next
such outage names itself: `connecting to the Kubernetes API timed out (no route, or a network
policy dropped the packet)` is a sentence an operator can act on, where
`Kubernetes Lease observation unavailable` was not.

## Sprint 2.43: The Broker's Self-Observation Never Matched Its Own Pod ✅

**Status**: Done (2026-08-11) — Phase `2` own-surface reopen (Standard A/N) on the same Bootstrap Broker
readiness contract as Sprints `2.39`, `2.40`, and `2.42`. Registered by the live investigation that
landed Sprint `3.34`: with the NetworkPolicy defect fixed, the broker's Kubernetes API calls
succeeded for the first time and exposed three further defects on the readiness path that the
dropped packets had masked. Each is registered here rather than patched silently
([development_plan_standards.md § L](development_plan_standards.md)).
**Implementation**: `src/Prodbox/Bootstrap/Broker/KubernetesWorker.hs`.
**Blocked by**: none.
**Deployment qualification**: pending — the change is to a label selector, a wire decoder, and an
image-reference check inside an existing readiness observation. No rendered manifest and no
readiness *verdict* semantics move; both substrate rows stay `pending`.
**Independent Validation**: pure and local — the selector is asserted against the chart's rendered
label, and the decoder against a captured `PodList` payload whose items carry no `apiVersion`/`kind`.
No live infrastructure.
**Live-proof**: pending — this sprint is what unblocks Sprint `3.34`'s validation 5.
**Docs to update**: none.

### Objective

`/readyz` gates on six dependencies, and `controller-image` is the last. Three separate defects sit
on it, each masked by the one before:

1. **The selector matched no Pod.** `brokerPodsUrl` queried
   `labelSelector=app.kubernetes.io/name=bootstrap-broker`, while the chart labels every broker
   object `prodbox-bootstrap-broker` — the repo-wide `prodbox-<component>` convention the broker's
   own NetworkPolicy peers (`prodbox-vault`, `prodbox-minio`) also use, and the one its
   ServiceAccount and token audience already follow. `KubernetesWorker.hs` held the only unprefixed
   occurrence in the repository. The `PodList` came back empty and `podListItems` produced
   `Bootstrap Broker PodList did not contain exactly one controller`.
2. **The decoder required fields Kubernetes omits.** `PodWire`'s `FromJSON` takes `apiVersion` and
   `kind` from each item, but Kubernetes omits both on items inside a `List` — they exist on the
   enclosing `PodList` only. Every decode of a non-empty list therefore failed with
   `Bootstrap Broker PodList response is invalid`. The single-Pod `GET` path, which shares `PodWire`
   and validates both fields at `decodeWorkerPod`, is correct as written and must keep validating
   them.
3. **The image check required a tag the harness never renders.** The controller-image validation
   computes `Text.stripSuffix ":latest"` on the container image reference, but
   `resolveCustomImageTag` renders a machine-id-derived tag on the home substrate and the fixed
   `prodbox-aws-substrate` tag on AWS. The chart's `values.yaml` default is `tag: latest`, and the
   harness overrides it on both substrates, so the suffix is absent on every supported path and the
   check returns `Bootstrap Broker controller image reference is invalid`.

These are one sprint because they are one observation's failure chain: each is only reachable once
its predecessor is fixed, so splitting them would register two sprints that cannot be validated.

### Deliverables

- ✅ **The selector names the label the chart renders.** `brokerPodsUrl` selects
  `app.kubernetes.io/name=prodbox-bootstrap-broker`.
- ✅ **The decoder accepts a list item.** `apiVersion` and `kind` are optional when parsing a
  `PodList` item and default to the values the enclosing list guarantees, while the single-Pod path
  keeps validating the fields it does receive.
- ✅ **The image check reads the tag that is rendered.** The repository is compared against the
  compiled owner by splitting the tag actually present, rather than by requiring `:latest`.

### Validation

1. ✅ The selector equals the chart's rendered `app.kubernetes.io/name` value, read out of
   `charts/bootstrap-broker/templates/_helpers.tpl` at test time rather than restated in the test.
2. ✅ A `PodList` payload shaped as the API returns one — `apiVersion`/`kind` on the list, absent on
   the item — is observed; an empty list is still refused.
3. ✅ Machine-id, `prodbox-aws-substrate`, and `latest` tags all validate against the compiled
   repository owner; a foreign repository and a registry-host port are both handled correctly.
4. ✅ `prodbox dev check` exit 0; `prodbox test unit` exit 0 (3332 + 27 + 33 + 27).

### Remaining Work

None. All three deliverables and all four validations are landed.

**Live-proof.** Sprint `3.34`'s validation 5 — a broker that reaches `"ready":true` on a live
cluster — is now unblocked on its code-owned dependencies. It remains a Standard-O axis for both
sprints and is proven by a live run, not by this closure.

## Sprint 2.45: Every Durable Broker Read Had a Validity Predicate That Accepted Anything ✅

**Status**: ✅ **Done (2026-08-13)** — Phase `2` own-surface reopen (Standard A) on the Bootstrap
Broker durable-store boundary this phase owns through Sprints `2.33`, `2.36`, and `2.42`.
**Implementation**: `src/Prodbox/Bootstrap/Broker/ProductionStore.hs` (`validValue` **deleted**;
seven payload predicates added), `src/Prodbox/Bootstrap/Broker/SecretWorker.hs`
(`secretWorkerCheckpointInvariantViolations`), `test/unit/BootstrapBrokerProductionBoundary.hs`.
**Blocked by**: none.
**Deployment qualification**: pending (**this moves a Standard-P persistence-protocol surface**).
No wire format, key, or envelope changes — every predicate is applied at the same point the old
one was, and accepts every value the broker writes. What changes is that a *read* of a
structurally-decodable but semantically-wrong record now returns `BootstrapStoreCorrupt` where it
previously returned the record. Both substrate rows are already `pending`, so nothing is
invalidated; the next qualification run must exercise the post-`2.45` read path.
**Independent Validation**: pure predicates over values built in-process, plus the CBOR seam that
produces an invalid one, validated by the unit suite — no cluster, no MinIO, no unsealed Vault, no
later phase. `prodbox dev check` exit 0; `prodbox test unit` exit 0 at main Hspec **3407/3407**.
**Docs updated**: none under `documents/` — the predicates' own Haddock names the doctrine
([chaos_hardening_doctrine.md § 23](../documents/engineering/chaos_hardening_doctrine.md)), which is
already authored.

### Objective

Close the row recording that `validValue _ = True` is the value-validity predicate for the
Bootstrap Broker's durable reads and compare-and-swaps, so `BootstrapStoreCorrupt` — the store's
own refusal constructor — was unreachable for every payload passed through it.

### The row's enumeration was substantially wrong, and correcting it is what made the sprint tractable

The row said the predicate covers "the session fence, prepared init envelope, encrypted init
response, final unlock bundle, child custody receipt, recovery delivery, **all four journals**, the
post-unseal handoff, and the secret-worker checkpoint" — eleven surfaces — and called it "nine
payload types".

| Surface named by the row | Predicate it actually had |
|---|---|
| Session fence | `validFenceObservation` — a real one |
| Root-init journal | `validRootInit` — a real one |
| Root-session journal | `validRootSession` — a real one |
| Child-custody journal | `validChildCustody` — a real one |
| Child-recovery journal | `validChildRecovery` — a real one |
| Post-unseal handoff | `validPostUnsealHandoff` — a real one |
| Prepared init envelope, encrypted init response, final unlock bundle, child custody receipt, child recovery delivery, secret-worker checkpoint | `validValue` |
| *(unnamed by the row)* the durable **storage-generation binding** — `bootstrapStoreReady`, `observeOrCreateStorageGeneration`, `advanceStorageGeneration` | `validValue` |

So **six** of the eleven surfaces the row listed were already defended, and the row missed the
seventh undefended one entirely — the storage-generation object, which is the coordinate every other
payload's binding is checked against. The measured figure is **7 payload types across 20 call
sites**, not nine across 21.

### The fix is one rule, not seven inventions

These records are persisted and read back through `Serialise` (CBOR), which reconstructs each field
positionally and **bypasses every smart constructor the type is otherwise built through**. That is
the conversion class [chaos_hardening_doctrine.md § 23](../documents/engineering/chaos_hardening_doctrine.md)
names, and the same seam Sprint `1.86` closed for Dhall decoding of the cluster topology. So each
predicate re-runs the constructors the decode skipped, plus the record's own cross-field arithmetic
where it has any:

- `validRootInitBinding` / `validChildCustodyBinding` — the bounded identifiers re-satisfy
  `mkBootstrapTransactionId` / `mkVaultStorageGeneration`.
- `validArtifactDigest` — the digest re-satisfies `mkArtifactDigest` (lower-hex SHA-256).
- `validEncryptedResponse` / `validChildEncryptedReceipt` — additionally, a non-empty share list. A
  receipt carrying no shares is the applied-but-unrecoverable state; carrying them is what the
  record is for.
- `validFinalUnlockBundle` — additionally `validUnlockShareThreshold`, the Shamir arithmetic
  `mkInitRecipientCommitment` already enforces at the mint site.
- `validSecretWorkerCheckpoint` — delegates to `secretWorkerCheckpointInvariantViolations`, placed
  **beside the type** in `SecretWorker.hs` (where `rootInitInvariantViolations` already lives), which
  is what lets `SecretWorkerDurableCheckpoint` stay exported abstractly.

### One decision recorded rather than glossed

`validUnlockShareThreshold` is a separate named function rather than an inline conjunct. A bundle
violating it is **unconstructible** through the smart constructors, so a test could only reach it by
crafting CBOR bytes — and asserting the composed predicate over a value no test can build would be
an absence no input could produce, the shape
[unit_testing_policy.md](../documents/engineering/unit_testing_policy.md) canonical statements 10 and
11 forbid. Exposing the decision over its two `Natural` inputs makes the rule itself falsifiable.

### Validation

1. Five unit cases, each falsifiable. The CBOR bypass is **reproduced rather than assumed**: the
   case asserts `mkArtifactDigest "not-a-sha256-digest"` is `Left`, then decodes that exact string
   into an `ArtifactDigest` through the newtype's own generic `Serialise` shape and shows the
   predicate refuses it. ✅
2. Mutation-proven: restoring `validChildEncryptedReceipt _ = True` fails the receipt case with
   `expected: False, but got: True`; restoring the file returns the suite to green. ✅
3. `prodbox dev check` exit 0; `prodbox test unit` exit 0 at main Hspec **3407/3407**. ✅

### Remaining Work

None on this row. **Two bounds are stated rather than implied.** First, the predicates re-run the
constructors the decode bypassed; they do **not** verify that a carried `ArtifactDigest` is the
digest *of the record that carries it*. That is a different and stronger property, it requires the
canonical serialization each digest was computed over, and no producer in this module exposes one —
recording it as unproven is more useful than implying it. Second, `validSecretWorkerCheckpoint`
constrains exactly one of nine arms, which is a decision rather than an omission: the other eight
carry closed constructors whose invariants are checked where they are minted, and the
`Unobservable` arm is the only one carrying free text.

## Sprint 2.46: The Refusal That Would Not Say Which Refusal It Was ✅

**Status**: ✅ **Done (2026-08-13)** — Phase `2` own-surface reopen (Standard A) on the Bootstrap
Broker surface this phase owns. Found by the first live Standard-P qualification campaign.
**Implementation**: `src/Prodbox/Bootstrap/Broker/EngineAdapter.hs`
(`brokerEngineErrorDiagnostic`, `brokerEngineErrorName`).
**Blocked by**: none.
**Deployment qualification**: pending (not invalidated). **The wire response is byte-identical** —
no status, body, or route changes. The addition is a server-side diagnostic line, which is not a
Standard-P surface by the enumeration.
**Independent Validation**: the renderer is pure and total over a closed constructor set; the
compiler enforces exhaustiveness, so a new engine error cannot become an unnamed refusal.
**Docs updated**: none under `documents/` —
[chaos_hardening_doctrine.md § 21](../documents/engineering/chaos_hardening_doctrine.md) already
authors the *Distinguishability* class this implements.

### Objective

Make it possible to tell which decision refused a Bootstrap Broker request, which was not possible
from outside the process and not possible from inside it either.

### Why this became the first Phase-2 sprint rather than the second

The campaign's third blocker is that `prodbox vault init` fail-closes with
`HTTP 409 {"status":"boundary-refused"}`. Diagnosing it meant answering "which refusal is that", and
**the answer was unavailable from every source at once**:

- **On the wire**, `boundary-refused` is produced by **five** distinct engine errors —
  `EngineProgramEvidenceRefused`, `EngineCapabilityAdmissionRefused`,
  `EngineCapabilityExecutionRefused`, `EngineFenceAcquireRefused`, and
  `EnginePhysicalCallRefused` — each of which discards its detail to a `_` in `boundaryReply`.
- **In the process**, the broker pod emits **zero bytes** of log output, so there is no second
  source to consult.

That combination is worth naming precisely, because it is worse than either half. A refusal with no
reason is recoverable if the service logs; a silent service is tolerable if its replies are
specific. Neither was true here, on the critical bring-up path.

**It also produced a wrong diagnosis before it produced a right one.** The first reading of this
failure attributed it to `secretWorkerBypassRefused` — one of the five — on the strength of having
grepped to it first. The evidence since gathered argues against that: `engineSecretWorkerBoundary`
is `Just` in production, the driver is fully wired to Kubernetes, and every step of
`driveRootInitialization` routes through `runAuthorizedSecretWorkerPhysical`, whose own arms produce
`EngineSecretWorkerBoundaryUnavailable` or `EngineSecretWorkerCallMismatch` — neither of which is
what was observed. Guessing among five indistinguishable candidates is what this sprint removes.

### Deliverables

- Every refused broker request writes one diagnostic line naming the route and the **engine error
  constructor**, plus the boundary class for the five errors that carry one.
- `brokerEngineErrorName` is a total case over the closed constructor set, so a newly-added engine
  error is a **compile error here** rather than an unnamed refusal in production.

### The bound, which is the design decision

**This renders the constructor, never the carried detail, and that is deliberate.** The detail on a
boundary refusal is frequently `Text.pack . show` over a typed error, and these are Vault bootstrap
paths; a `show` that one day carries token or share material would publish it to the pod log —
exactly the class [vault_doctrine.md § 20](../documents/engineering/vault_doctrine.md) forbids.
Constructor names are a closed, authored, finite set and cannot carry a secret.

So this answers **which decision refused**, not **why**. That is precisely the question that was
unanswerable, and it is answered without taking on a leak risk to do it. Widening to the detail
requires a redaction analysis of every producer and is its own work — recorded, not smuggled in
here.

**A second bound**: this covers refusals reaching `engineBrokerInterpreter`. A request refused
earlier — by the fail-closed interpreter, or by admission before the engine — does not pass through
this point.

### Validation

1. `prodbox dev check` exit 0 (formatter, linter, warning-clean build). ✅
2. `prodbox test unit`, `test integration cli`, `test integration env` — see
   [README.md](README.md). ✅
3. Live: the rolled-out broker names the refusing constructor for the `vault init` path, which is
   what the follow-up sprint consumes. 🔄

### Remaining Work

None on the observability row. The defect it makes diagnosable is its own work, and is deliberately
not guessed at here. **That work is now Sprint `2.47`, registered below (2026-08-14).**

## Sprint 2.47: A Teardown That Preserves State By Design Preserves The Fence That Blocks The Next Bring-Up ✅

**Status**: ✅ **Done (registered, part-landed, and closed 2026-08-14)** — Phase `2` own-surface work
on the Bootstrap Broker fence this phase owns through Sprints `2.33`, `2.36`, `2.42`, and `2.46`.
Phase `2` stays ✅ closed on its code-owned surface throughout: this sprint ran as the `Pending
Removal` shape Standard I describes, never as a reopen (Standard N).
**Implementation**: `src/Prodbox/Bootstrap/Broker/Fence.hs`
(`BootstrapFenceOwnerWorkerObservation`, `bootstrapFenceOwnerCleanupFromWorkerObservation`,
`PredecessorLiveness`/`classifyPredecessorLiveness`),
`src/Prodbox/Bootstrap/Broker/KubernetesWorker.hs` (`kubernetesObserveFenceOwnerWorker`,
`fenceOwnerWorkerFromResponse`), and `src/Prodbox/Bootstrap/Broker/ProductionEngine.hs`
(`acquireFence`'s acquire → retire → re-acquire sequence).
**Blocked by**: none.
**Deployment qualification**: pending. This was the recorded blocker of the **first Standard-P
qualification campaign** ([README.md](README.md)); the code-owned half is closed and the campaign's
next attempt is the live proof below.
**Live-proof**: ✅ **PASSED on the operator host, 2026-08-14** — see *The live proof, run* below. Not
a point probe: three consecutive retirements of three distinct fence generations, each with its own
receipt digest.
**Evidence**: `prodbox dev check` exit 0; `prodbox test unit` exit 0 at main Hspec **3453** plus 27,
33, and 27 (3446 + this sprint's 7); `prodbox test integration cli` **57/57**.
**Independent Validation**: every decision this sprint added or changed is a pure function over
typed inputs, and the Kubernetes read-back is decided by an exported pure decoder over a status code
and a response body. The whole surface is validated with no cluster, no Vault, and no MinIO
(Standard N).
**Docs to update**: [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md) — row moved to
`Completed`; root `README.md`'s `.data/` preservation paragraph;
[bootstrap_readiness_doctrine.md](../documents/engineering/bootstrap_readiness_doctrine.md) — fence
acquisition semantics changed, so the doctrine records the new rule. All three landed.

### Objective

A failed bring-up leaves a durable `bootstrap-session-fence` object that no supported command clears,
and `cluster delete --cascade` preserves `.data/` **by design** because that tree also holds per-run
Pulumi state. The fence lives in the same tree. An expired predecessor was never taken over
implicitly — correct for single-writer safety — so every subsequent bring-up refused with
`BootstrapFenceAcquireExpiredPredecessor`, and the host could never complete `prodbox vault init`
again.

The full causal chain, the killed hypotheses, and the second blocker discovered behind this one are
recorded on the ledger row rather than restated here
([legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md), Standard I:186).

**The row's prediction was confirmed, which is what earned it an owner.** It closed by saying "the
next failed run will re-poison the host identically". It did: a fence object dated `2026-08-13 23:06`
was present on the operator host, written after the 2026-08-13 hand-clearing by a later abandoned
bring-up, and it survived the `--cascade` teardown that followed. That is a second independent
reproduction obtained for the cost of one `find`, and it moved the row from a predicted recurrence to
a measured one.

### What landed

1. **`PredecessorLiveness` replaces a `Bool` on the acquire path.** `predecessorExpired` folded all
   three `AttemptDeadlineRefusal` arms into *expired*; two of them —
   `AttemptClockUnobservable` and `AttemptClockRegressed` — mean *cannot determine*. Landed first
   precisely because it is fail-open **in shape**: the moment a positive expiry authorises a
   retirement, an unreadable clock would authorise one too. `decideBootstrapFenceRetire` already drew
   this distinction; the acquire path was brought level with it rather than a second rule being
   invented. Class-D distinguishability,
   [chaos_hardening_doctrine.md § 21](../documents/engineering/chaos_hardening_doctrine.md), same
   conversion class as Sprints `4.76` and `4.78`.
2. **A production `BootstrapFenceOwnerCleanupObservation` producer.**
   `kubernetesObserveFenceOwnerWorker` observes worker presence **by fence generation**, and
   `bootstrapFenceOwnerCleanupFromWorkerObservation` adapts it to the cleanup fact the retire
   decision consumes. This is the type's first producer since it was defined.
3. **`acquireFence` wires acquire → retire → re-acquire.** A positively-expired predecessor is now
   retired through the CAS that already existed, then the successor re-decides **once** against the
   confirmed post-retirement read-back.
4. **Two more closed name-only refusal renderings**, `bootstrapFenceRetireRefusalName` and
   `bootstrapLeaseRefusalName` — see *The narration gap this sprint found on its way out*.

### The mechanism already existed and could not be used, which is the sprint's real content

**Options 1 and 3 from the ledger row were never needed.** `decideBootstrapFenceRetire` already
retires an expired owner and is **more rigorous than all three recorded options**: it requires three
independent facts and refuses closed on ambiguity in each — the durable deadline elapsed on a
*trusted* clock, the exact Lease absent or expired, and the exact owner's cleanup read back absent.

**Why it was never wired, stated exactly rather than as "a design decision".**
`decideBootstrapFenceRetire` had **zero production callers** — the grep returned its definition, its
export, and one comment. `confirmBootstrapFenceRetireCas` likewise. The store half *was* wired
(`casRetireBootstrapSessionFence` → `retireFence`), so the two ends existed and nothing connected
them: the enforcing-nothing shape Sprints `4.68`, `4.72`, and `4.77` each found.

**And it could not be wired as it stood.** The retire decision requires a
`BootstrapFenceOwnerCleanupObservation`, whose `BootstrapFenceOwnerAbsent` arm was bound to a
`SecretWorkerCleanupBinding` — pod UID, session id, session accessor, request digest, storage
generation, fence generation, receipt digest. **The durable fence carries only three of those
seven.** The predecessor's pod UID, session id, accessor, and receipt digest are not recoverable from
the one record that survives it. That is the structural reason the mechanism was unwired, and no
amount of choosing between the row's three options addressed it.

### Why proving the worker Pod is gone is enough, and why that is not a concession

Absence of the predecessor's worker Pod does **not** prove absence of a Vault session it may still
hold — and nothing short of widening the durable fence could prove that, because the predecessor's
session id and accessor are not in the record that survives it.

They do not need to be. **The retirement is the revocation, not merely what precedes it.** Every
Vault effect and every durable mutation re-reads this exact fence through
`authorizeBootstrapVaultEffect` / `authorizeBootstrapStoreMutation` immediately before acting, so a
predecessor that somehow survived fails closed at its next effect with `BootstrapFenceUseFenceLost`
or `BootstrapFenceUseFenceStale`. Retiring the fence positively withdraws the predecessor's
authority; the three facts are what make it safe to conclude the predecessor is *finished*, and the
per-effect recheck is what makes it safe to be wrong.

This bound is stated in the Haddock at the wiring site rather than left to be re-derived.

### The absence claim is whole rather than sampled

The worker Pod is **one fixed coordinate** — `bootstrap-secret-worker` in the Broker namespace, built
by a closed native manifest builder and granted by that exact name in the Broker's Role
(`charts/bootstrap-broker/templates/tokenreview-rbac.yaml`). At most one can exist. So the decoder
has three outcomes and the middle one is what makes the producer possible at all:

- `404` — the coordinate is empty, so no worker exists for any generation.
- `200` carrying a **different** fence generation — the sole coordinate is occupied by someone else,
  which is itself proof this generation's worker is gone.
- `200` carrying **this** fence generation — present. A terminating Pod still counts as present; a
  deletion in flight is not a completed absence.

Everything else — unparseable body, missing or non-canonical fence-generation annotation, rejected
identity, any other status, transport failure — is unobservable, never absence. Absence is the only
outcome that can authorize a takeover, so it is the only one that must be positively proven.

The generation is compared in the adapter in **both** directions: an answer about generation `G'` is
not an answer about generation `G`, whichever way it points, and both mismatches are unobservable.
That is [chaos_hardening_doctrine.md § 24](../documents/engineering/chaos_hardening_doctrine.md) made
mechanical at the one place a boundary answer becomes a retirement authorization.

### Seven prescribed remedies were refuted by measurement, and the pattern is the finding

The first four were recorded when this sprint registered and part-landed; the last three were found
closing it. Each was found by measuring before or just after writing.

1. **Option 2 was inert.** Treating a predecessor from a different `VaultStorageGeneration` as vacant
   cannot fire in the reported scenario: `observeOrCreateStorageGeneration` returns the **existing**
   binding whenever the object is present, and `vault-storage-generation` lives in the same preserved
   `.data/` tree as the fence. Both were observed on the operator host — generation written
   `19:09:43`, fence `23:06:12`, same day. The successor carries **the same** generation, the
   comparison is `G == G`, and the takeover never triggers. The most attractive option was the one
   that does nothing.
2. **The row's "this is a design decision, not a patch" framing.** The choice was not the sprint's
   content; the unbuildable cleanup observation was.
3. **This sprint's own fence-generation *selector* claim.** The fence generation is an **annotation**,
   and Kubernetes cannot select on annotations — neither label nor field selectors reach them.
4. **This sprint's own new refusal constructor.** `BootstrapFenceAcquirePredecessorLivenessUnobservable`
   was added so the undetermined case would have its own name; the unit case written to pin it proved
   the arm **cannot fire**, because `decideBootstrapFenceAcquire` derives the *request's* attempt
   deadline from the same clock observation before it reads the store. It was **deleted rather than
   shipped** (Sprint `4.78`'s precedent), and the test now pins the behaviour that actually occurs.
5. **Shape 1's own replacement mechanism — "list broker-owned pods by the `app.kubernetes.io/name`
   label and re-filter client-side on the annotation" — was unnecessary, and would have been
   *worse*.** There is one worker Pod coordinate and it has a fixed name, so a direct `GET` on that
   name is authoritative: no list, no client-side re-filter, and no dependency on the label at all.
   The label list would also have been **less** precise, because the same label matches the Broker's
   own controller Pod — `brokerPodsUrl` uses exactly that selector for controller self-observation —
   so the re-filter would have had to exclude the controller as well. The correction recorded on
   registration replaced a wrong mechanism with an unnecessary one.
6. **"Every construction site including the fakes must supply the new field."** There are no fakes:
   `KubernetesWorkerBoundary` has **exactly one** construction site in the tree,
   `productionKubernetesWorkerBoundary`. The change the sprint called "larger and more invasive than
   the landed half" was one field and one site. The estimate was prose; the count is a grep.
7. **The never-renewed fence Lease looked like a defect and is not.** `bootstrapLeaseManifestForFence`
   writes `leaseDurationSeconds = 300` once at acquisition and nothing renews it, while
   `authorizeFenceUse` re-confirms the Lease — including its expiry — before **every** effect. That
   reads as a hard 300-second ceiling on any fenced operation. It is not, because
   `maximumBrokerRequestDeadlineMilliseconds` is `5 * 60 * 1000` — exactly 300 seconds — and the
   Lease's `renewTime` is stamped *after* the request was accepted, so the Lease deadline is always
   later than the request deadline and the `min` in `authorizeFenceUse` never selects it. **The
   coupling is real and undeclared**: two `300`s in different modules with no stated relationship, and
   raising the request budget alone would silently make every long operation fail closed at
   `BootstrapLeaseExpired`. Recorded rather than absorbed, and owned by Sprint `2.48`.

### The narration gap this sprint found on its way out

The second blocker recorded behind the stale-fence row is a Lease refusal whose **constructor was
never captured** — the ledger holds the paraphrase "no Lease present", where `BootstrapLeaseNotFound`
and `BootstrapLeaseObservationUnobservable` would have named different faults with different causes.
The reason it was not captured is in this phase's own code: `ensureLease` narrated the fixed string
`lease not confirmed` for **all six** `BootstrapLeaseRefusal` constructors. That is the exact
collapse Sprint `2.46` fixed one level up for the acquire refusals, and this function was missed by
it.

Closed here, on this sprint's own surface, by the same closed name-only rule — two of the six
refusals carry a `BootstrapLeaseBinding`, which carries the owner nonce, so the constructor name is
published and the payload is not. This does not fix the second blocker. It is the mechanism by which
the next reproduction will name it, which is why it belongs to the sprint that found it rather than
to the sprint that will close it.

### Deliverables

- **✅ The decision, argued from measurement.** All three recorded options refuted, one by direct
  measurement of the operator host.
- **✅ A production `BootstrapFenceOwnerCleanupObservation` producer.**
  `kubernetesObserveFenceOwnerWorker` on `KubernetesWorkerBoundary`, its pure decoder
  `fenceOwnerWorkerFromResponse`, and the pure adapter
  `bootstrapFenceOwnerCleanupFromWorkerObservation`.
- **✅ Wire acquire → retire → re-acquire** in `acquireFence`. The re-acquire is a **structurally**
  bounded second pass — a separate function with no path back into the retire branch — rather than a
  depth counter, so a predecessor that survives the CAS refuses instead of looping.
- **✅ The acquire path's `predecessorExpired` is three-valued.**
- **✅ The second blocker split out** as Sprint `2.48`, with its own ledger row, the measurements that
  narrow it, and the narration fix above already landed so the next reproduction names the
  constructor. The sprint text was explicit that it "gets its own registered sprint, not a mention".
- **✅ A regression case that fails before the fix.** The acquire → retire → re-acquire sequence is
  asserted end to end, starting from the exact refusal the operator host reported, and the refusal
  arms are asserted beside it — a live worker for the same generation, an unreadable worker
  observation, and a foreign-generation answer all still refuse. A permissive branch alone proves
  nothing.

### Validation

1. **`prodbox dev check`** exit 0.
2. **`prodbox test unit`** exit 0 — main Hspec **3453**, plus 27, 33, and 27. Seven new cases: four
   over the adapter and the acquire → retire → re-acquire sequence in
   `test/unit/BootstrapBrokerSafety.hs`, three over the boundary decoder in
   `test/unit/BootstrapBrokerProductionBoundary.hs`.
3. **`prodbox test integration cli`** **57/57**.
4. **The live proof, stated as a sequence rather than a state** — ✅ **passed**, below.

### The live proof, run (2026-08-14)

**The setup step was not needed, because the host was already armed.** The precondition this proof
requires — a host whose previous bring-up was abandoned and whose fence survived the teardown — was
the operator host's actual state, measured before anything was run: `bootstrap-session-fence` written
`2026-08-13 23:06:12.988`, `vault-storage-generation` written `19:09:43.633` beside it, and no RKE2
install at all. Those are the exact objects and timestamps the ledger row recorded. So the proof is a
bring-up on the real poisoned host, not a reconstruction of one.

**What the Broker recorded on the first run**, verbatim from its own stderr:

```text
bootstrap-broker retired expired fence generation 1; worker-absence receipt 08f276ff…f808
```

`BootstrapFenceAcquireExpiredPredecessor` — the refusal that had wedged this host for two days and
across five bring-ups — did not fire. The durable object was rewritten at `15:15:21`, so the CAS
reached the store rather than the decision merely being taken. The worker-absence proof came from the
new boundary observer answering `404` on the sole worker coordinate.

**It is a consecutive-run result, not a point probe**, which is what
[Standard P](development_plan_standards.md#p-deployment-qualification-and-counterexample-closure)'s
aggregate rule requires of a cleanup claim. Five bring-ups were run:

| Run | Fence state on entry | Result |
|-----|----------------------|--------|
| 1 | generation 1, stale from 2026-08-13 | **retired**, re-acquired as generation 2 |
| 2 | generation 2, still inside its deadline | `BootstrapFenceAcquireOverlap` — correctly refused |
| 3 | generation 2, still inside its deadline | `BootstrapFenceAcquireOverlap` — correctly refused |
| 4 | generation 2, deadline elapsed | **retired**, re-acquired as generation 3 |
| 5 | generation 3, deadline elapsed | **retired**, re-acquired as generation 4 |

Three retirements of three distinct generations, each publishing a **different** receipt digest
(`08f276ff…`, `1f63524a…`, `8a146171…`) — which also demonstrates live that the receipt is derived
from the read-back rather than constant. And the refusal arm refused twice in between, on its own
merits, without being contrived: runs 2 and 3 are the negative control this sprint would otherwise
have had to construct.

### A third defect, found by the live run rather than by reading

`acquireFence` CASes the fence and **then** calls `ensureLease`. When the Lease step fails, the
request returns an error and **the durable fence stays held** — nothing releases it. That is why runs
2 and 3 saw `Overlap`: run 1's successor fence was live and abandoned in the same breath.

**Before this sprint that leak was permanent.** Once the abandoned fence's deadline elapsed, the next
acquisition would have refused `BootstrapFenceAcquireExpiredPredecessor` forever — the very defect
this sprint closed. After it, the leak is self-healing within one operation deadline, which is what
runs 4 and 5 demonstrate. **So the retirement is load-bearing for a defect that was not the one it was
written for**, and that is the strongest available argument that it belongs on this path rather than
being a narrower fix to the recorded symptom. The leak itself is recorded on the ledger and owned by
Sprint `2.48`, which is where the Lease failure that triggers it lives.

### A Standard-C correction to Sprint `4.82`'s recorded evidence

`prodbox dev check` did **not** reproduce at exit 0 on this worktree, and the cause was not this
sprint. Sprint `4.82` added `cascadePhaseDerivedFrom` to `CascadePhaseOutcome` and updated its own
test block, but a Sprint-`4.76` block in `test/unit/Main.hs` still built the record as a literal —
`-Wmissing-fields` under `dev check`'s `-Werror` build, which `prodbox test unit` does not enforce
and therefore did not catch. Corrected in place: the fixture now goes through `independentPhase`, the
smart constructor `4.82` added for exactly this shape, which also states what the fixture means. The
lesson is recorded rather than the number quietly swapped: **`test unit` passing is not `dev check`
passing, and an evidence line that names both must have run both.**

### Remaining Work

**None. The code-owned surface and the live proof are both closed.**

**The bound is stated.** This sprint owns the fence that blocks re-acquisition. It does not own the
underlying question of what `--cascade` should preserve — `.data/` preservation is deliberate,
load-bearing for per-run Pulumi state, and documented in root `README.md`; narrowing it is
[Phase 4](phase-4-lifecycle-canonical-paths.md)'s surface, not this one (Standard N). It also does
not own the second blocker, which is Sprint `2.48` below.

## Sprint 2.48: A Lease Refusal Recorded As A Paraphrase Cannot Be Told From Five Other Lease Refusals ✅

**Status**: ✅ **Done (registered, part-landed, and closed 2026-08-14)** — Phase `2` own-surface work
on the same Bootstrap Broker fence surface. Phase `2` stays ✅ closed on its code-owned surface; a
sprint landing on a closed phase is the `Pending Removal` shape Standard I describes, not a reopen
(Standard N).
**Implementation**: `bootstrapLeaseManifestForFence` and `bootstrapLeaseFromResponse` in
`src/Prodbox/Bootstrap/Broker/KubernetesWorker.hs`; `bootstrapFenceLeaseDurationSeconds` in
`src/Prodbox/Bootstrap/Broker/Settings.hs`; `abandonFreshlyAcquiredFence` in
`src/Prodbox/Bootstrap/Broker/Fence.hs` and `acquireFence`'s `releaseFreshlyAcquiredFence` in
`src/Prodbox/Bootstrap/Broker/ProductionEngine.hs`.
**Blocked by**: none. It was blocked on **evidence**, not on a prerequisite, and the distinction is
deliberate — a `Blocked by` naming a missing observation would be a status word doing a
reproduction's job.
**Deployment qualification**: pending. This is the blocker that sits **behind** Sprint `2.47`'s, so it
is on the first Standard-P campaign's path.
**Live-proof**: ✅ **root cause found, fixed, and verified live 2026-08-14** — the fence Lease is
created for the first time. See *The cause, and the fix that proved it* below.
**Independent Validation**: `confirmBootstrapLease`, `bootstrapLeaseFromResponse`, the derived
Lease TTL, and `abandonFreshlyAcquiredFence` are all pure over typed inputs, so every arm is pinned by
unit cases with no cluster (Standard N).
**Docs to update**: ✅ [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md) — both rows
this sprint owned moved to `Completed`; ✅ `documents/engineering/bootstrap_readiness_doctrine.md`
§ 3.3.2 and § 3.3.3, because the Lease's liveness contract did change.

### Objective

With the stale fence cleared, acquisition refused at `confirmBootstrapLease` with — as recorded —
"no `coordination.k8s.io` Lease present in the `bootstrap-broker` namespace", although the Broker's
Role grants `create` on leases and `get`/`update` on `bootstrap-broker-fence`. The ledger row for the
stale fence is explicit that this is a live defect rather than stale state, and that it is **not that
row**.

**The first thing to fix was the record, and Sprint `2.47` already fixed it.** "No Lease present" is
a paraphrase. `BootstrapLeaseNotFound` and `BootstrapLeaseObservationUnobservable` are different
faults with different causes, and `ensureLease` narrated the same fixed string for both — and for
four others. That narration is now constructor-named, and **the very next reproduction used it.**

### What the live run settled, and what it refuted (2026-08-14)

**The recorded paraphrase was wrong.** The constructor is `BootstrapLeaseObservationUnobservable`,
**not** `BootstrapLeaseNotFound`. The Lease was not missing; the observation could not be made. Every
inference that started from "no Lease present" started from the wrong fault.

**Two hypotheses were killed by measurement, and one of them was this plan's own.**

1. **RBAC is not the cause — ruled out directly, not argued.** Against the Broker's own
   ServiceAccount: `can-i create leases.coordination.k8s.io` → **yes**;
   `can-i get leases.coordination.k8s.io/bootstrap-broker-fence` → **yes**. The Role and RoleBinding
   both exist in the Broker namespace.
2. **The transient-window reading was refuted by repetition, and it was the reading this sprint
   found most attractive.** The RoleBinding was created at `19:15:13Z` and the first refusal landed
   eight seconds later, which matches `bootstrapLeaseFromResponse`'s own comment that `403` stays
   non-terminal "because a cold cluster legitimately answers it while the broker's RoleBinding has
   not yet been applied" — a near-perfect fit. It is wrong: the refusal reproduced **identically** on
   four further bring-ups spanning twelve minutes, long after RBAC was established. **A hypothesis
   that explains the first observation and not the fifth is not a diagnosis**, and recording that is
   worth more than the hypothesis was.

**What the Broker's Kubernetes access demonstrably can do**, which narrows the remaining causes
sharply: the same credential, in the same request, successfully read the worker Pod coordinate — that
`404` is what produced the worker-absence receipt Sprint `2.47`'s retirement published. So this is not
a dead API client, not a network partition, and not a token problem.

**The remaining collapse is three-way, and it is now the sprint's whole content.**
`BootstrapLeaseObservationUnobservable` still covers a transport failure, a non-success API status,
and a structurally invalid response body. Naming the constructor moved the record from a six-way
collapse to a three-way one; it did not finish the job.

### The cause, and the fix that proved it

**`Lease.spec.renewTime` is a `MicroTime`, and Kubernetes parses it with the Go layout
`2006-01-02T15:04:05.000000Z07:00` — exactly six fractional digits, mandatory.** Aeson's
`ToJSON UTCTime` renders a *variable* count: it trims trailing zeros and can emit up to twelve from
picosecond resolution. `bootstrapLeaseManifestForFence` encoded the `UTCTime` directly, so the API
server rejected the body with `400 Bad Request` — **deterministically**, because `getCurrentTime`
essentially never lands on exactly six significant digits. The Broker's fence Lease had therefore
never been creatable, on any run, which is why `prodbox vault init` had never got past it.

**Proven server-side rather than argued**, with `kubectl create --dry-run=server` against this exact
resource — four probes, each falsifiable:

| `renewTime` | Result |
|-------------|--------|
| `…37.123456789012Z` (12 digits) | `BadRequest` — `cannot parse "789012Z" as "Z07:00"` |
| `…37.123456789Z` (9 digits) | `BadRequest` — `cannot parse "789Z" as "Z07:00"` |
| `…37.123456Z` (6 digits) | **accepted** |
| `…37Z` (0 digits) | `BadRequest` — `cannot parse "Z" as ".000000"` |

**The fix is `kubernetesMicroTime`**, which renders exactly six fractional digits. Truncation is
toward the past, which is also the safe direction: the rendered instant is never later than the
`UTCTime` it came from, so the `renewTime > wallNow` guard in `bootstrapLeaseFromResponse` cannot be
tripped by the encoding itself.

**Verified live, and the verification is a positive observation rather than the absence of an
error**: after the fix the Lease object exists in the Broker namespace —
`bootstrapLeaseFromResponse` confirmed it, and `kubectl get leases` shows
`bootstrap-broker-fence` held by the fence's owner nonce. The bring-up then advanced **past** the
Lease to a stage it had never reached (see Sprint `2.49`).

**A second, smaller defect closed with it.** The non-success detail read
`Bootstrap Lease GET returned a non-success status` — on a decoder the ensure path reaches with a
`POST`/`PUT`, and with the status dropped entirely, so a `400` from a malformed body and a `500`
from a broken API server read identically and neither named the call. It now reports
`Bootstrap Lease request returned HTTP <code>`. **The status code is the single fact that would have
identified this defect in one run instead of five**, and it was being discarded.

### The landed half

`bootstrapLeaseRefusalName` now carries the **reason** for the two constructors whose payload is
already a fixed, payload-free string, while the two that carry a `BootstrapLeaseBinding` still publish
their constructor and nothing else. That is the same rule applied to different payloads, not a
relaxation of it.

**It is safe because Sprint `2.42` already made it safe**, and this consumes that guarantee rather
than re-establishing it: these details are built by `unobservableReason` over
`kubernetesTransportFailureLabel`, which maps every `HttpExceptionContent` constructor onto a fixed
label with no wildcard arm and never inspects the `Request` — precisely because it carries an
`Authorization: Bearer` header — and `2.42` asserted with a planted token that no bearer material
reaches a rendered reason.

**It has not yet been observed in the deployed Broker, and the reason is worth recording rather than
retrying blindly.** The runtime image tag is `prodbox-<machine-id>`
(`resolveMachineIdentity` in `src/Prodbox/CLI/Rke2.hs`) — **host-scoped by design, not
content-addressed** — so a source change does not move the tag, the Deployment spec does not change,
and the running Pod is not replaced. The deployed Broker on this host is still the `19:15:13Z` Pod.
This is expected behaviour, not a defect, and it is stated here so the next attempt reaches for a Pod
replacement rather than another reconcile.

### What is already measured, without a cluster

Every line below is a grep, not an inference, and each one narrows the search before a single live
run is spent:

1. **`kubernetesEnsureBootstrapLease` has exactly one caller** — `acquireFence`'s `ensureLease`. There
   is no second write path to confuse the reproduction with.
2. **`BootstrapLeaseMissing` — the observation behind `BootstrapLeaseNotFound` — is produced at
   exactly one place: HTTP `404` in `bootstrapLeaseFromResponse`.** Nothing else in the tree
   constructs it from a live response.
3. **RBAC failure cannot produce it.** `403` maps to `BootstrapLeaseUnobservable` by an explicit
   guard, and the guard's own comment says why: a cold cluster legitimately answers `403` while the
   Broker's RoleBinding has not yet been applied. So if the refusal really was `NotFound`, the cause
   is **not** the Role.
4. **Which relocates the question.** A `404` from `POST .../namespaces/<ns>/leases` means the
   namespace or the API group is absent — neither of which is plausible for a Pod that is running in
   that namespace. The likelier reading is that the refusal came from the **`GET`** path
   (`kubernetesObserveBootstrapLease`, which `observeFenceUse` calls before every effect), and the
   question is then not "why did creation fail" but "why was the Lease absent between acquisition and
   first use". The reproduction distinguishes these, and Sprint `2.47`'s narration is what lets it.
5. **An undeclared coupling on the same surface, found by Sprint `2.47` and handed here.** The fence
   Lease is written once with `leaseDurationSeconds = 300` and never renewed, while `authorizeFenceUse`
   re-confirms its expiry before every effect. That is safe today only because
   `maximumBrokerRequestDeadlineMilliseconds` is `5 * 60 * 1000` — the same 300 seconds — and the
   Lease's `renewTime` is stamped after the request was accepted, so the Lease deadline is always the
   later of the two and the `min` never selects it. The two constants live in different modules with
   no stated relationship. Raising the request budget alone would make every long operation fail
   closed at `BootstrapLeaseExpired`, and the failure would look like a Lease defect rather than a
   budget change.

### Deliverables

- **✅ One reproduction that names the constructor**, not a description of it. Taken 2026-08-14; the
  answer was that the refusal was never `NotFound` at all, and that correction is recorded above as
  the result it is.
- **✅ The reason published for the two constructors that can carry one safely**, reducing the
  collapse from six-way to three-way.
- **✅ The cause, argued from the reason** rather than from the constructor: a `MicroTime` encoding
  the API server rejects with `400`, proven server-side with four `--dry-run=server` probes.
- **✅ The fix, and a live verification that is a positive observation** — `kubernetesMicroTime`, and
  the fence Lease existing in the cluster for the first time.
- **✅ The misleading non-success detail** replaced with the status code it was discarding.
- **✅ Unit cases pinning the encoding**: exactly six fractional digits across five input precisions,
  never an instant later than the one given, and distinct rendering per status code.
- **✅ The undeclared 300-second coupling declared, not removed by renewing.**
  `bootstrapFenceLeaseDurationSeconds` now derives from
  `maximumBrokerRequestDeadlineMilliseconds` by ceiling division, and the manifest builder reads it
  instead of the literal `300`. **The evidence that chose declaration over renewal is that renewal is
  adversarial to Sprint `2.47`, not merely more machinery**: `decideBootstrapFenceRetire` takes over
  an abandoned fence only against a **positively expired** Lease, and the state it exists to recover
  from is exactly a bring-up abandoned partway. A renewer thread outliving the wedged operation would
  hold the Lease live forever, the fence could never be retired, and the host would return to the
  permanent wedge `2.47` closed. A Lease that expires on its own is the mechanism, not an omission.
  Ceiling division rather than `div 1000` because a budget that is not a whole number of seconds
  would otherwise violate the invariant silently; the tightest satisfying value is chosen because a
  longer TTL delays the instant a successor may declare a predecessor expired.
- **✅ The fence leak on the acquisition path compensated**, closing the second ledger row this
  sprint owned rather than leaving it to outlive its owner. `acquireFence` CASed its fence and then
  abandoned it when `ensureLease` failed; `abandonFreshlyAcquiredFence` now produces an exact-value
  CAS back to vacant with the released generation as the high-water floor. **It needs no facts of its
  own, and that is the design rather than a shortcut**: retirement must prove three things about an
  owner it cannot see, whereas this releases a fence *this call created moments ago*, and
  `authorizeBootstrapVaultEffect` / `authorizeBootstrapStoreMutation` both require a confirmed Lease
  witness before any effect — so a fence that never carried a witness cannot have authorized
  anything. Retirement could not have served in any case: it requires the durable operation deadline
  to have **elapsed**, and a freshly acquired fence's has not. **Only the freshly CAS'd fence is
  released**; a resumed fence pre-existed the call and an earlier attempt of the same request may
  already have run effects under it. **No refusal constructor was invented** — every
  `BootstrapLeaseRefusal` justifies the release equally — on the same rule by which Sprint `2.47`
  deleted an unreachable constructor rather than shipping it.
- **✅ Unit cases pinning both.** The Lease-TTL invariant
  (`1000 * duration >= maximumBrokerRequestDeadlineMilliseconds`), its tightness (one second shorter
  violates it), and the rendered body carrying the derived value; and for the release, that the
  vacated floor is the released generation itself — a floor one lower would let a successor re-mint
  the same generation, which is the property the whole fence scheme rests on — plus that a fence
  differing in any field conflicts rather than being vacated.

### Validation

1. `prodbox dev check` exit 0; `prodbox test unit`; `prodbox test integration cli`.
2. The live proof: one bring-up that reaches `ensureLease` on a cluster where the fence is
   acquirable, with the constructor recorded.

### Remaining Work

**None.** Both items this sprint carried open are closed above: the 300-second coupling is declared
with one owner and one derivation, and the acquisition-path fence leak — measured directly by the
live run, where runs 2 and 3 refused `BootstrapFenceAcquireOverlap` against run 1's abandoned
successor fence — now compensates instead of leaking. Its ledger row moves to `Completed` with this
sprint rather than outliving its owner, which is the shape this plan has caught three times.

**One thing the closure does not claim.** The compensation is best-effort by construction: the
original Lease refusal reaches the caller whether the release CAS lands or not, because a failed
release is a cleanup of this call's own side effect and not a second diagnosis. When it fails, the
behaviour is exactly what existed before — the leak, which Sprint `2.47`'s retirement path already
makes self-healing within one operation deadline rather than permanent.

**The discipline this sprint was bound by, and the outcome it produced**: two hypotheses were refuted
by measurement before the cause was found — the ledger's own paraphrase, and the transient-RBAC
window that matched the decoder's comment and an eight-second timing fit. The rule that broke the
deadlock was to stop hypothesising and make the refusal say more: publishing the reason took one
build, and the reason named the cause immediately. **Three of this session's findings were reached
that way rather than by reasoning about the code**, which is the argument for the narration work
being load-bearing rather than cosmetic.

## Sprint 2.49: An Attestation That Tries Every Candidate And Reports Only That All Of Them Failed ✅

**Status**: ✅ **Done (registered, landed, and closed 2026-08-14)** — Phase `2` own-surface work on the
Bootstrap Broker's secret-worker attestation and on a defect Sprint `2.47` introduced that only became
reachable once Sprint `2.48` landed. Evidence: `prodbox dev check` exit 0, `prodbox test unit` exit 0,
and a live run in which the named refusal identified its cause on the first attempt. Phase `2` stays ✅ closed on its code-owned surface; a
Planned sprint on a closed phase is the `Pending Removal` shape Standard I describes, not a reopen
(Standard N).
**Implementation**: `firstAttestedRequest` and `waitForAttestedWorker` in
`src/Prodbox/Bootstrap/Broker/HostSecretWorker.hs`, over `workerRequestFromRunningResponse` in
`src/Prodbox/Bootstrap/Broker/KubernetesWorker.hs`.
**Blocked by**: none.
**Deployment qualification**: pending. This is now the **first** blocker on the bring-up path, having
been uncovered by Sprint `2.48`'s fix clearing the one in front of it.
**Live-proof**: 🧪 pending (Standard O, non-blocking) — reproduction is already available and
deterministic on the operator host.
**Independent Validation**: `firstAttestedRequest` is pure over a candidate list and a response body,
so every arm is exercised by unit cases with no cluster (Standard N).
**Docs to update**: [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md) when the row
moves to `Completed`.

### Objective

With the fence retired (Sprint `2.47`) and the Lease creatable (Sprint `2.48`), the bring-up now
reaches secret-worker attestation and fails there:

```text
Vault initialize failed: attest Bootstrap secret worker:
  "worker Pod does not match any expected closed operation"
```

**This is the third instance of one defect class in one session, and by now the pattern is the
finding rather than the instance.** `firstAttestedRequest` walks its candidate list and discards
every candidate's reason:

```haskell
go (candidate : rest) = case workerRequestFromRunningResponse … of
  Right request -> Right request
  Left _        -> go rest
```

`workerRequestFromRunningResponse` returns a specific `Left` for each mismatch — phase, deletion
timestamp, ServiceAccount, operation, image digest, and each annotation — and every one of them is
thrown away. The operator is told that nothing matched, never what did not match, and the candidate
list has several entries, so the message is a disjunction reported as a dead end.

Sprints `2.46`, `2.47`, and `2.48` each closed exactly this shape one layer up: `2.46` for the
five acquire refusals, `2.47` for the six Lease refusals, `2.48` for the status code inside the
non-success arm. **Each time, the narration was what produced the next diagnosis** — `2.48`'s root
cause was found within one build of publishing the reason. This sprint is the same move, one layer
further in.

### Deliverables

- **✅ A refusal that names the mismatch.** `firstAttestedRequest` now reports every candidate's
  operation and the field it disagreed about, instead of `Left _ -> go rest`. The empty-expectation
  case is split out as a distinct fault: nobody expecting anything is a caller defect, not a Pod that
  matched nothing.
- **✅ The payload judgement — and it was not needed, which measuring first is what established.**
  This deliverable was registered assuming a comparison failure quotes the values it compared. It
  does not: `requireCreateEqual` is `Left (label <> " mismatch")` and renders neither side, so the
  reasons are payload-free by construction and propagating them needs no new rule. **That is the
  eighth prescribed remedy this row has refuted by measurement**, and the first belonging to `2.49`
  itself.
- **✅ The ordering hazard in `retireExpiredPredecessor`**, above, with a regression case pinning both
  directions.
- **✅ `EngineSecretWorkerRefused` named to its nested constructor**, closing the widest remaining
  collapse on this surface.
- **The cause, once the refusal names it**, and the fix.
- **Unit cases over `firstAttestedRequest`**: an empty candidate list, a matching candidate behind a
  non-matching one, and a wholly non-matching list whose refusal names the first reason.

### Validation

1. `prodbox dev check` exit 0; `prodbox test unit`; `prodbox test integration cli`.
2. The live proof: a bring-up that reaches an initialized Vault on the operator host.

### Remaining Work

**Landed**: the attestation narration and its three unit cases, the `2.47` ordering fix and its
regression case, and the twenty-constructor secret-worker naming.

**Open**: none. The cause the naming made readable is
`EngineSecretWorkerRefused/StoredRequestBindingMismatch`, read on the first run after deploying the
change — the fourth consecutive time this method produced a diagnosis within one build. It is a
distinct defect on a distinct object and is registered as Sprint `2.50` rather than absorbed here,
because it is the same design decision `2.47` faced rather than a follow-on patch.

## Sprint 2.50: The Same Sentence As Sprint 2.47, With "Checkpoint" In Place Of "Fence" ✅

**Status**: ✅ **Done (registered and closed 2026-08-14)** — Phase `2` own-surface work on the durable
secret-worker checkpoint. Phase `2` stays ✅ closed on its code-owned surface; a sprint landing on a
closed phase is the `Pending Removal` shape Standard I describes, not a reopen (Standard N).
**Implementation**: `requestBindingMismatch`, `intentBindingMismatch`, `SecretWorkerBindingSite`,
`SecretWorkerBindingField`, and the checkpoint resume/roll arms of `driveSecretWorker` in
`src/Prodbox/Bootstrap/Broker/EngineSecretWorker.hs`; `engineSecretWorkerErrorName` in
`src/Prodbox/Bootstrap/Broker/EngineAdapter.hs`.
**Blocked by**: none.
**Deployment qualification**: pending. This is now the **first** blocker on the bring-up path.
**Live-proof**: ✅ **passed 2026-08-14 on the operator host, with nothing cleared by hand** — the
bring-up advanced past this refusal and the roll is proven in the durable object, not inferred from a
changed message. See *The live proof* below.
**Independent Validation**: `requestBindingMismatch` and the resume/roll decision are pure over typed
inputs; every arm is exercised without a cluster (Standard N).
**Docs to update**: ✅ [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md);
✅ `documents/engineering/bootstrap_readiness_doctrine.md`.

### Objective

**This phase's Sprint `2.47` was titled "a teardown that preserves state by design preserves the
fence that blocks the next bring-up". This sprint is that sentence with one word changed.**

With the fence retirable (`2.47`), the Lease creatable (`2.48`), and the secret-worker refusal
nameable (`2.49`), the bring-up refused at:

```text
EngineSecretWorkerRefused/StoredRequestBindingMismatch
```

`secret-worker-checkpoint` sits in the preserved `.data/` tree beside the fence, written
`2026-08-14 17:39:44` by the first run that ever got past the Lease. `--cascade` preserves it for the
same reason it preserves the fence: the tree also holds per-run Pulumi state.

### The checkpoint, decoded — and the correction it forced

The registered deliverable was to decode the completion state rather than assume it. **Decoded, and
the plan's own description of the object was wrong in two ways.**

It is not Vault-enveloped. The bootstrap store's `StoredEnvelope` is canonical CBOR over
`SecretFreeWorkerRequest` — *secret-free by construction*, which is what the type name says — inlined
in the MinIO object. It was readable directly, with no Vault session, on a host whose Vault is
uninitialized. **The sprint was registered believing the decode needed a facility the wedged host by
definition could not offer**, and one `xxd` refuted that.

The decode:

| Field | Checkpoint (store version 2) | Held fence (store version 19) |
|-------|------------------------------|-------------------------------|
| constructor | **`InternalNoWorkerReceipt`** — pre-receipt | — |
| operation | `SecretWorkerPrepareInitialization` | — |
| session accessor | **`WorkerSessionNotIssued`** | — |
| fence generation | **7** | **10** |
| owner nonce | `6f79287b…` | `c8ac043c…` |
| action digest | `db260513…` | `db260513…` |
| request digest | `76fc5869…` | `76fc5869…` |
| storage generation | `vault-423fc5df…` | `vault-423fc5df…` |
| operation deadline | `1786743884304979` | `1786753521528879` |

**Three of the seven compared fields differ, not two.** This plan recorded fence generation and owner
nonce; the operation deadline is `acceptedAt + budget` and is therefore minted per invocation just as
inevitably. That is a small number and it was wrong in the same direction as the "eleven layers"
withdrawal recorded on 2026-08-14: **an inventory stated in prose is not a measurement.** The refusal
being payload-free is precisely why nobody caught it — which is the argument for the first
deliverable below rather than a separate observation about it.

**The arm is named.** `decideSecretWorkerRecovery` returns `SecretWorkerRecoveryDestroyAndReprompt`
for this checkpoint, and `recoverStoredWorker`'s catch-all binding guard sat **above** that arm and
shadowed it.

### The decision, and why it is narrower than any of the three options registered

The three candidates were a retirement mirroring the fence's, a widened roll arm, or a supported
recovery verb. **The evidence chose the roll arm, bounded three ways — and the bound this sprint was
scoped by is what does the choosing rather than being argued across.**

1. **No result exists to lose.** The bound was that a fence is an exclusion record while a checkpoint
   is a *result* record. That is a statement about checkpoints which **carry** a result.
   `InternalNoWorkerReceipt` is the constructor whose entire meaning is that no receipt was captured;
   its receipt and its result are both `Nothing` by construction. The caution is measurably
   inapplicable to the state that was actually stuck — and the codebase had already made this
   judgement for the same constructor under a *matching* binding, where `DestroyAndReprompt` has
   always destroyed and re-prompted.
2. **A strictly superseded generation, not "some field differs".** Within one fence generation the
   identical-binding requirement is **unchanged**: an incomplete checkpoint for a *different
   operation* under the same fence still fails closed, because the worker operations of one bootstrap
   session are ordered and discarding an interrupted predecessor could skip a stage. A checkpoint
   from a *newer* generation is refused outright — that would mean this invocation is the stale one.
   Exactly one of the seven cases in the pre-existing exhaustive mismatch table changes behaviour.
3. **The predecessor's worker is destroyed, not assumed absent.**
   `discardUnreceiptedSecretWorker` issues a UID-preconditioned delete and then waits for absence,
   refusing outright if a replacement worker occupies the fixed coordinate. **That is stronger than
   the worker-absence observation Sprint `2.47` built** — it does not infer absence, it causes it.
   Holding the current fence is what makes it safe to do so: every Vault effect and durable mutation
   re-reads that exact fence immediately before acting, so a surviving predecessor bound to an
   earlier generation fails closed at its next effect.

**What stays refused**: every checkpoint carrying a receipt, on any binding. Those are result records
mid-cleanup whose cleanup binding names a Pod UID, session id and session accessor a successor cannot
reconstruct; discarding one could leak a live Vault session. The replay hazard is unchanged and still
gated where it was — `interruptionRequiresRefusal` decides whether an un-receipted worker may be
re-prompted at all, and a refusing interruption yields `DestroyAndRefuse`, which the widened arm never
sees.

**The same wedge one stage earlier is closed with it.** A durable `InternalWorkerIntent` from a
superseded generation had the identical dead end in `resumeWorkerIntent`, and is strictly safer to
roll: no Pod UID is bound, no receipt exists, and nothing needs discarding. It rolls at the
`recoverStoredWorker` call site rather than inside `resumeWorkerIntent`, because that function is also
reached from `beginFreshWorker` with an intent minted moments earlier, where a mismatch is a boundary
defect and must stay a hard refusal.

### Deliverables

- **✅ The refusal names what it refused.** `EngineSecretWorkerStoredRequestBindingMismatch` was
  payload-free and produced at **five** distinct sites — a stale durable checkpoint, a stale durable
  intent, a boundary that minted an intent for the wrong invocation, a boundary that created a
  workload for a different intent, and the authoritative reconcile path — all reaching the operator as
  one word. It now carries a `SecretWorkerBindingSite` and the list of fields that disagreed, rendered
  as `StoredRequestBindingMismatch/stored-request[fence-generation,owner-nonce,operation-deadline]`.
  **Field labels only, never values**, and this needed no new rule: Sprint `2.49` already established
  that `requireCreateEqual` renders neither side of a comparison, so these reasons are payload-free by
  construction. **This is the fifth instance of the collapse Sprints `2.46`–`2.49` each closed one
  layer up**, and the cost is not hypothetical — it is the wrong field count two sections above.
- **✅ The completion state decoded** rather than assumed, and the arm named from it.
- **✅ The decision**, taken on that evidence and bounded three ways above.
- **✅ The bound stated and kept**, not argued across: a receipted checkpoint from a superseded
  generation is still refused, with a case covering every cleanup stage from receipt capture onward.
- **✅ A regression case that fails before the fix**, and it was run against the frozen prior
  behaviour rather than asserted: with the superseded-generation guard disabled the roll case fails
  with exactly `StoredRequestBindingMismatch StoredRequestBinding [BindingFenceGeneration]`, while
  both negative controls — a newer-generation checkpoint and a receipted one — still pass.

### Validation

1. ✅ `prodbox dev check` exit 0; `prodbox test unit` exit 0; `prodbox test integration cli` 57/57;
   `prodbox test integration env` 57/57.
2. ✅ The live proof, below.

### The live proof

**Both directions were observed on the operator host, on its own objects, with nothing cleared by
hand.**

The **pre-fix** refusal reproduced deterministically against the deployed Broker, twice in a row and
each time behind a fresh fence retirement:

```text
bootstrap-broker retired expired fence generation 9;  worker-absence receipt 745452d2…
bootstrap-broker refused /v1/bootstrap/vault/init: EngineSecretWorkerRefused/StoredRequestBindingMismatch
bootstrap-broker retired expired fence generation 10; worker-absence receipt 02983f95…
bootstrap-broker refused /v1/bootstrap/vault/init: EngineSecretWorkerRefused/StoredRequestBindingMismatch
```

After deploying the fix the same command advanced **past** that refusal, and the proof is the durable
object rather than the absent error. `secret-worker-checkpoint`, stuck since `17:39:44` at store
version 2 bound to fence generation 7, was rewritten at `23:32` to store version **4**, fence
generation **13**, a fresh owner nonce and a fresh Pod UID. That is `driveSecretWorker` discarding a
superseded pre-receipt checkpoint and CAS-rolling it onto a request bound to the fence it holds —
exactly the arm this sprint widened, and nothing else in the tree writes that object.

**The run did not reach an initialized Vault, and what stopped it is a new and distinct blocker**,
registered as Sprint `2.51` rather than absorbed here: the worker Pod is created and then never
starts, because the image reference the Broker pins it to cannot be resolved by the registry. That is
the fifth defect in this chain and the fourth to become reachable only once the one in front of it was
fixed.

**Sprint `2.49` recorded why the distinction between the two directions is worth keeping**: a live
proof is only as strong as the states it actually reached, and `2.47`'s passed while an arm behind it
was still broken. This sprint's proof covers the arm it changed — the roll — and claims nothing about
the stages beyond it.

### Remaining Work

None on the code-owned surface.

## Sprint 2.51: A Config Digest And A Manifest Digest Are The Same Sixty-Four Hex Characters ✅

**Status**: ✅ **Done (2026-08-15)** on the code-owned surface, with the changed arm **live-proven**
and the forward bring-up proof outstanding behind a downstream refusal this sprint does not own —
see Live-proof. Phase `2` stays ✅ closed; an Active sprint on a closed phase was the `Pending
Removal` shape Standard I describes, not a reopen (Standard N).
**Implementation**: `src/Prodbox/Bootstrap/Broker/KubernetesWorker.hs` (`ControllerImageIdentity`,
`WorkerImagePullReference`, `mkWorkerImagePullReference`, `renderWorkerImagePullReference`,
`controllerImageFromResponse`, `kubernetesObserveControllerImage`, `observeControllerImage`,
`workerPodManifestForIntent`, `workerRequestFromCreateResponse`, `decodeWorkerPod`,
`WorkerPodDecodeReason`, `renderWorkerPodDecodeReason`, `declaredImagePin`, `resetVaultStorage`,
`ensureVaultResetPod`, `vaultResetPodManifest`, `validateResetPod`),
`src/Prodbox/Bootstrap/Broker/ProductionSecretWorkerBoundary.hs`,
`src/Prodbox/CheckCode.hs` (`checkWorkerImagePullReferenceOwner`,
`workerImagePullReferenceViolations`), and
`test/unit/BootstrapBrokerProductionBoundary.hs`.
**Blocked by**: none.
**Deployment qualification**: pending. This is now the **first** blocker on the bring-up path.
**Live-proof**: ✅ **the arm this sprint changed is proven on the operator host (2026-08-15)**;
🧪 the forward bring-up-to-initialized-Vault proof is **pending behind a downstream refusal this
sprint does not own**, which is the Standard-O split and the distinction Sprint `2.49` insisted on —
*a live proof is only as strong as the states it actually reached.* On a wiped-and-rebuilt cluster
the secret-worker Pod is now declared as `…/prodbox-runtime:prodbox-<machine-id>` — the pullable tag
rather than `@sha256:<config digest>` — it **pulled and ran** instead of sitting in
`ImagePullBackOff`, and its observed `imageID` is `sha256:82ae5092…`, **identical to the
controller's**, so the attestation identity this sprint moved to holds on real Pods. The bring-up
then stops strictly further along, at a refusal with a different cause: the worker exits `1` logging
`Root initialization journal is not pristine`, against a `.data/` tree the canonical teardown
preserves by design.
**Independent Validation**: `imageDigestFromRuntimeId` is pure over a `Text`, and
`controllerImageDigestFromResponse` is pure over an HTTP status and body, so whichever remedy is
chosen is pinned by unit cases with no cluster (Standard N).
**Docs to update**: [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md) on closure;
`documents/engineering/bootstrap_readiness_doctrine.md` if the worker-image attestation contract
changes; `documents/engineering/local_registry_pipeline.md`, because the defect is a property of the
local build-and-push pipeline meeting a by-digest pull.

### Objective

With the fence retirable (`2.47`), the Lease creatable (`2.48`), the refusals nameable (`2.49`), and
the durable checkpoint rollable (`2.50`), the bring-up now creates its secret worker and the Pod never
starts:

```text
Vault initialize failed: attest Bootstrap secret worker:
  "worker Pod does not match any expected closed operation:
   prepare-initialization -> worker Pod response is invalid; …"
```

### The cause, measured rather than argued

**The worker Pod is in `ImagePullBackOff`, and the registry names the reason itself.** From the
Broker namespace's own events:

```text
Failed to pull image "127.0.0.1:30080/prodbox/prodbox-runtime@sha256:e3c7ab7c…":
  failed to resolve reference … unexpected status from HEAD request to
  /v2/prodbox/prodbox-runtime/manifests/sha256:e3c7ab7c…: 500 Internal Server Error
```

**Three probes against the live registry settle what that digest is**, and the third is the one that
matters:

| Request | Result |
|---------|--------|
| `manifests/prodbox-<machine-id>` (by tag) | **200**, `Docker-Content-Digest: sha256:52d86a90…` |
| `manifests/sha256:e3c7ab7c…` (the digest the Broker pinned) | **500** |
| the controller Pod's `status.containerStatuses[].imageID` | `sha256:e3c7ab7c…`, with **no registry prefix** |

So the Broker derives the worker's image reference from the controller Pod's own `imageID` — which on
this host is the image's **config digest**, the identity containerd reports for an image that is
present locally rather than pulled from a registry — and constructs `repo@sha256:<config digest>`.
The registry's manifest digest is `sha256:52d86a90…`. **The two are different objects, and only one of
them is addressable by a registry pull.**

**The chain is read end to end rather than inferred from the symptom**, which matters because the
symptom appears four modules away from the cause: `allocateSecretWorkerIntent` calls
`kubernetesObserveControllerImageDigest`; `controllerImageDigestFromResponse` reads the controller
Pod's `status.containerStatuses[].imageID` through `imageDigestFromRuntimeId`; `mkSecretWorkerIntent`
carries the result as `secretWorkerIntentImageDigest`; `workerImageReference` renders
`<repo>@sha256:<digest>`; and `workerPodManifestForIntent` places it in the Pod with
`imagePullPolicy: IfNotPresent`. The live Pod's `image` field is exactly the controller's `imageID`,
which closes the loop.

**The structural reason this was not caught by a type is worth stating, because it is the whole
sprint.** `imageDigestFromRuntimeId` validates that the value is `sha256:` followed by sixty-four
lower-hex characters. A config digest and a manifest digest are *both* exactly that. They are
indistinguishable by syntax, distinguishable only by which endpoint resolves them, so no smart
constructor over the text can separate them — which is precisely the shape
[chaos_hardening_doctrine.md § 24](../documents/engineering/chaos_hardening_doctrine.md) describes: an
observation has a layer, and this one names the container runtime's layer while being consumed as the
registry's.

**One probe of this sprint's own was wrong, and recording it is cheaper than repeating it.** The first
registry probe asked for the tag with only the Docker v2 manifest `Accept` header and got **404**,
which reads as "the registry lost the image" and would have produced a diagnosis about the push rather
than the pull. Adding the OCI manifest and index media types to `Accept` returned **200**. The 404 was
the probe's fault, not the registry's — *a measurement is only as good as the request that made it.*

### The three candidate remedies, one refuted and one favoured on evidence

The remedy is a design decision, not a patch, and the resemblance to a one-line fix is a reason for
care. The digest pinning exists so the worker is provably the **same image** as the controller that
attests it; changing what is pinned changes what is proven.

**Option A — resolve the config digest to a manifest digest before pinning — is refuted, and not on
cost.** It is not implementable: the OCI distribution API offers no reverse index from a config digest
to the manifest that references it. `GET /v2/<name>/manifests/<config-digest>` is exactly the request
kubelet already makes and the registry already answers **500**. Nothing the Broker could ask would turn
one identity into the other. **That is the useful half of this analysis** — the option that reads as
the obvious correct fix cannot be built at all.

**Option B — pin the controller's own declared image reference — is pullable but proves less.** The
controller's `spec.containers[].image` is `…/prodbox-runtime:prodbox-<machine-id>`, a *mutable* tag, so
a worker launched from it is not provably the same bytes as the controller.

**Option C is favoured: keep the observed runtime identity as the attestation, and use the declared
reference only to tell the kubelet where to look.** The defect's precise shape is that
`controllerImageDigestFromResponse` already reads the controller's declared reference — it validates
that reference's repository against the compiled static — and then **discards it**, carrying forward
only the config digest, which is the one of the two that no registry can resolve. Option C carries
both: the worker Pod's `image` becomes the controller's declared, pullable reference, while
attestation continues to require the worker's observed `imageID` to equal the controller's observed
`imageID`.

**This is stronger than what the spec-level pinning achieved, not a relaxation of it**, and the
doctrine already says why:
[bootstrap_readiness_doctrine.md § 0.4](../documents/engineering/bootstrap_readiness_doctrine.md) —
*external state is observed, not commanded*. A digest in a Pod spec is a **request**; comparing the
two Pods' runtime identities is an **observation** of what the kubelet actually ran.

**Why it is still sprint-sized rather than a patch**, stated so the next session does not
re-discover it: `ControllerImageObservation` must carry both identities instead of one, which reaches
`SecretWorkerIntent`, `workerImageReference`, `workerPodManifestForIntent`, and the
declared-versus-observed equality inside `decodeWorkerPod` — which must become conditional, because a
tag reference carries no digest to compare. That last point is the only place where a check is
genuinely surrendered, and the argument that it costs nothing (the runtime comparison subsumes it)
belongs in the implementation with a unit case pinning it, not in this paragraph.

### Deliverables

- **The remedy chosen on an argument about what the pinning proves**, not on which change is smallest.
  Option A is already refuted above and Option C is already favoured; what remains is the
  implementation and the unit case that makes the surrendered spec-conformance check demonstrably
  redundant.
- **The two digests distinguished at the type level or at the boundary that consumes them**, so a
  config digest can no longer be handed to a registry pull silently.
- **The decode collapse closed.** `workerRequestFromRunningResponse` and `workerRequestFromSelfResponse`
  both discard their decoder's reason with `const`, so a Pod that never started and a malformed API
  response read identically — the **sixth** instance of the shape Sprints `2.46`–`2.50` each closed one
  layer up, and the one that hid this cause behind four identical candidate reasons. The redaction
  question is real here and must be answered rather than assumed: an Aeson decode error can quote a
  value, and the worker Pod's annotations carry a Vault session accessor.
- **Unit cases** over `imageDigestFromRuntimeId` pinning the distinction, and over the decode arm
  pinning that a not-yet-started Pod is reported as such.

### Validation

1. `prodbox dev check` exit 0; `prodbox test unit`; `prodbox test integration cli`.
2. The live proof: a bring-up reaching an initialized Vault on the operator host.

### What the implementation found that the registration could not

**The remedy the registration favoured is right, and the layer it named for carrying it is wrong —
which one command settled.** The registration said `ControllerImageObservation` must carry both
identities and that this "reaches `SecretWorkerIntent`". `SecretWorkerIntent` is the **durable**
type: it is persisted before the POST so a lost create response is recoverable, and its codec is
`deriving anyclass instance Serialise` — generic, positional, arity-checked. Measured directly
rather than reasoned about:

```text
narrow bytes: [132,0,7,97,120,245]
wide decode of narrow bytes: Left (DeserialiseFailure 1 "Wrong number of fields: expected=5 got=4")
```

So adding a field makes every already-written checkpoint undecodable. **That failure is not
recoverable by anything this plan has built**: `decodeStoredEnvelope` returns `BootstrapStoreCorrupt`
at the envelope, and `recoverStoredWorker` — including Sprint `2.50`'s roll of a superseded
pre-receipt checkpoint — runs only *after* a successful decode. The registered shape would therefore
have wedged the operator host permanently, on exactly the surface Sprints `2.47` and `2.50` each
closed a permanent wedge. **The registration was not wrong to favour Option C; it had simply not
measured the codec.**

**The correct layer is the one the doctrine argument already implied.** A pull reference is *where
the kubelet looks*; the runtime digest is *what is proven*. Recording an addressing hint in a durable
binding would be the same layer confusion one level up. The declared reference is therefore observed
afresh inside `kubernetesCreateWorkerWorkload`, which is the one place both the fresh path
(`beginFreshWorker`) and the resumed path (`recoverStoredWorker` → `resumeWorkerIntent`) pass through.
The durable intent is unchanged, byte for byte.

**That relocation gained a check rather than only surrendering one.** Because the create boundary now
observes the controller image anyway, it can refuse when the freshly observed runtime digest no longer
equals the one the intent pinned — a controller redeployed between intent allocation and Pod creation
is now refused *at the boundary, with its own reason*, instead of failing attestation four stages
later. No such check existed before.

**And it changes a deadline composition, which is stated rather than absorbed.** The create path
shares one `workerApiBudgetMicros` deadline across every request it makes, and that count rises from
at most two to at most three. The budget is deliberately **not** widened: the added request is the
same in-cluster PodList read `allocateIntent` already performs under the same budget, and exhausting
the deadline is a fail-closed refusal the outer reconcile retries rather than a wrong result.
Recording it matters because absolute-deadline composition is a Standard-P surface, and a sprint that
adds a round trip to a bounded path without saying so is how that ledger goes stale.

### The second live instance, in the same module and never registered

`resetVaultStorage` builds the Vault **pristine-reset** Pod by the identical concatenation, from the
identical observation. It would have failed the identical way the moment a reset ran. It is fixed
with the worker Pod rather than left for the next session to rediscover, and `vaultResetImageReference`
— the duplicate of `workerImageReference` that made two copies of one defect — is deleted rather than
repaired.

### The surrendered check, discharged as a unit case rather than a paragraph

The registration owed an argument that dropping `declaredDigest == observedDigest` costs nothing. It
is now three assertions instead: a tag-declared Pod whose runtime identity **matches** the intent
attests; a tag-declared Pod whose runtime identity **differs** is still refused; and a Pod that *does*
pin a digest must still agree with the runtime. Two checks are added in exchange — the worker's
declared reference must name the compiled worker repository (it previously was not checked at all),
and the digest-pinned arm survives intact.

### The sixth decode collapse, and the redaction question answered by construction

`decodeWorkerPod` returned `Either String` and both host-side decoders discarded it with `const`. It
now returns a closed `WorkerPodDecodeReason`. **The redaction question was real and is settled
structurally, not by auditing Aeson**: every payload in the type is a controller-authored literal — a
field label or an annotation key — and the one reason whose text could quote the body,
`WorkerPodResponseUnparsable`, deliberately drops the parser's message. A unit case feeds a body
carrying a distinctive Vault session accessor through three failing arms and asserts the accessor
appears in neither the rendered reason nor the observation an operator reads.

**One arm of that collapse was a decoder defect, not just a mute one.** `PodWire` required
`status.containerStatuses`, which Kubernetes omits entirely on a Pod whose container has not started
— so "not scheduled yet" was reported as *"the response is invalid"*, indistinguishable from
malformed JSON. It is now `WorkerPodNotStarted`, and an `ImagePullBackOff` Pod — container status
present, `imageID` empty — is `WorkerPodImageNotResolved`. **Those are the two states this sprint's own
defect produces**, and neither could be named while it was being diagnosed.

### The boundary is compiled-checked, and its scope is stated rather than assumed

`checkWorkerImagePullReferenceOwner` forbids, in the Broker's modules, a Pod `"image" .=` fed by
anything but `renderWorkerImagePullReference`, and any image reference assembled by concatenating
`"@"`. It is scoped to `src/Prodbox/Bootstrap/Broker/` **deliberately**: three live-reachable sites
outside it still assemble a digest reference, and a check that fails on work no sprint has taken is a
broken build rather than a guard. Widening it belongs to Sprint `4.83`.

### Remaining Work

None on the code-owned surface.

**The live proof caught this sprint under-implementing its own headline deliverable, which is the
strongest argument available for taking it.** The decode-collapse work landed at
`workerAttestationFromResponse` and `workerExitFromResponse` but **not** at
`workerRequestFromRunningResponse` and `workerRequestFromSelfResponse` — the two functions the
registration named explicitly. Both still discarded the reason with `const`, and because that arm
compiles either way, `dev check`, a 3479-case unit suite, and both 57/57 integration suites all
passed over it. What exposed it was the bring-up printing `worker Pod response is invalid` four
times with no reason attached — *the exact string the sprint existed to delete*. It is fixed, and the
lesson is narrower than "test more": **a deliverable phrased as removing a collapse is only verified
by an observation that the collapsed value is gone**, and no local gate here could make that
observation.

**The forward proof stops at a refusal this sprint does not own, and the boundary is stated rather
than blurred.** With the worker Pod pulling and running, the bring-up now fails at the worker's own
exit: `Root initialization journal is not pristine`, against the `.data/` tree
`cluster delete` preserves by design. That is a different cause at a later stage, it is not
`ImagePullBackOff`, and attributing it to this sprint would be the "a live proof is only as strong as
the states it actually reached" error Sprint `2.49` recorded, run in reverse.

**A search for the same defect elsewhere found three candidates and measured all three away, which
is worth more than a fourth fix would have been.** `workerImage` in
`src/Prodbox/ControlPlane/TargetSecretWorkerKubernetes.hs` and the two credential-provisioner Jobs
all build `repository@<digest>` with `imagePullPolicy: Always`, and all inherit their digest from
`docker image inspect --format {{.Id}}` in `src/Prodbox/Lib/ChartPlatform.hs`. That reads as the same
defect and **is not one**: measured on the operator host, `.Id`, `.RepoDigests`, and the registry's
`Docker-Content-Digest` are all `sha256:52d86a90…`, while Kubernetes' `imageID` is `sha256:e3c7ab7c…`.
`docker inspect` and the kubelet are **different reporters**, and carrying this sprint's measurement
across to the other one was the error — caught only because the value was read rather than reasoned
about, which is the same move that produced this sprint's own diagnosis.

What survives is narrower and is registered as Sprint `4.83`: those three references are pullable
because this host runs Docker's containerd image store, under which `.Id` happens to be the manifest
digest, and nothing in the repository declares or asserts that dependency. A separate and genuinely
independent row records that their observers compare a declared reference against itself and hold no
runtime-identity attestation at all — the check this sprint added to the Broker.

## Documentation Requirements

**Engineering docs to create/update:**

- `documents/engineering/bootstrap_readiness_doctrine.md` — ✅ updated by Sprint `2.47`. Fence
  acquisition semantics changed: a positively-expired predecessor is now retired and taken over
  rather than refused forever, so the doctrine records the three facts that authorize it, the
  direction the worker observation is scoped in, and why per-effect fence recheck is what makes the
  takeover safe. ✅ updated again by Sprints `2.48`/`2.50`: the fence Lease's TTL is a derived value
  with one owner rather than a coincidence between two modules, an acquisition that cannot establish
  its Lease releases the fence it just created, and a pre-receipt checkpoint from a strictly
  superseded fence generation is rolled rather than refused forever.
- `documents/engineering/local_registry_pipeline.md` — 📋 pending under Sprint `2.51`. The
  worker-image defect is a property of this pipeline meeting a by-digest pull: an image built and
  pushed locally is reported by the container runtime under its **config** digest, while a registry
  can only resolve a **manifest** digest, and the two are the same sixty-four hex characters.

**Product docs to create/update:**

- None.

**Cross-references to add:**

- ✅ Root `README.md` — the `.data/` preservation paragraph names this consequence and its resolution.
- ✅ `DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md` — the stale-fence row moved to `Completed` on
  Sprint `2.47`; the second Lease blocker was registered as its own `Pending Removal` row owned by
  Sprint `2.48` and moved to `Completed` when that sprint closed, together with the acquisition-path
  fence-leak row; the durable-checkpoint row moved to `Completed` on Sprint `2.50`.

## Sprint 2.52: The Gateway Endpoint Has No Localhost Escape [✅ Done]

**Status**: Done (2026-08-23) — Phase `2` reclosed on Gateway Runtime's boot/config consumer.
**Implementation**: `src/Prodbox/Gateway/Daemon.hs`, `src/Prodbox/Gateway/Settings.hs`, and
`src/Prodbox/Gateway/Types.hs`.
**Deployment qualification**: pending — endpoint/capability wiring changes, so prior aggregate
evidence does not describe this revision.
**Independent Validation**: daemon-settings decode tables and a fake object-store interpreter prove
configured, missing, malformed, and unreachable endpoints without a cluster or later phase.
**Docs to update**: `documents/engineering/config_doctrine.md`,
`documents/engineering/distributed_gateway_architecture.md`, `DEVELOPMENT_PLAN/README.md`,
`DEVELOPMENT_PLAN/00-overview.md`, `DEVELOPMENT_PLAN/system-components.md`, and
`DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md`.

### Objective

Remove the Gateway daemon's compiled MinIO endpoint fallback. `boot.minio_endpoint_url` already
exists, but `None` is converted into a hard-coded in-cluster endpoint, so missing configuration and
the home deployment happen to select the same target. A daemon on another substrate can therefore
contact the wrong service rather than refuse.

### Deliverables

- The legacy Gateway boot projection consumes the validated `context.minio_endpoint` supplied by
  Sprint `1.92`; `None` or a malformed value yields a typed unavailable/refusal arm.
- Delete the `fromMaybe` endpoint literal and the comments that describe it as an implicit default.
- Tests inject endpoints through `DaemonBootDhall`/the typed settings seam; no production
  environment variable or test-only production branch selects an endpoint.
- The target cutover still removes generic Gateway object-store authority. This sprint only makes
  the surviving pre-cutover consumer truthful; it does not widen Gateway's final role.

### Validation

1. Two distinct configured endpoints reach the fake client exactly and produce distinct requests.
2. `None`, empty, malformed, and unreachable inputs each refuse with the source field and never
   attempt a compiled address.
3. Source/gate proof finds no complete MinIO service endpoint literal in Gateway production code.
4. Gateway daemon/unit suites and `prodbox dev check` pass.

### Remaining Work

None on the sprint-owned surface. Sprint `3.42` owns chart-side projection of the validated
deployment context; the endpoint consumer itself is closed and refuses until that projection is
present.

### Closure

`DaemonBootDhall.minio_endpoint_url` now narrows into a `GatewayMinioEndpoint` observation with
explicit unavailable and configured states. Configured values are checked for an HTTP(S) scheme,
authority, non-emptiness, and whitespace before they enter `DaemonConfig`; the endpoint is part of
the boot-change comparison.

The legacy continuity-store consumer can obtain a URL only through
`gatewayMinioEndpointUrl`. `None` returns a field-named refusal, and the former compiled in-cluster
service address is deleted. Tests project two distinct endpoints exactly, prove absent/empty/
malformed inputs refuse, send an unreachable endpoint to a fake client without substitution, and
mutation-prove that either the compiled address or removal of the refusal fails `dev check`.

The full unit command, both built-frontend integration commands, and `prodbox dev check` pass on
this revision. Deployment qualification remains pending under Standard O/P.

## Sprint 2.53: A Dead Port-Forward Is Not Broker Readiness [✅ Done]

**Status**: Done (2026-08-23) — opened by the live reconcile that closed Sprint `3.43`.
**Implementation**: `src/Prodbox/Bootstrap/Broker/PortForward.hs` and focused unit coverage.
**Deployment qualification**: pending — this changes the host-to-Broker capability wiring/startup
sequence and must be included in Sprint `6.5`'s current-revision campaign.
**Independent Validation**: exact subprocess projection and live local reconcile from the existing
half-built state.
**Docs to update**: `documents/engineering/bootstrap_readiness_doctrine.md`,
`DEVELOPMENT_PLAN/README.md`, `DEVELOPMENT_PLAN/00-overview.md`, and
`DEVELOPMENT_PLAN/system-components.md`.

### Objective

Make host access to the loopback-only Bootstrap Broker wait for the deployed server before opening
its bounded Kubernetes Service port-forward. A port-forward process that exited before the Pod was
running must not be represented as a live transport while the client retries HTTP against its dead
local socket.

### Deliverables

- Observe the exact Broker Deployment rollout through the same explicit namespace, environment,
  and working directory as the port-forward before minting a credential or starting the transport.
- Preserve the Broker's Pod-loopback listener and the host's loopback-only `--address`; no ClusterIP,
  NodePort, Gateway, or widened listener becomes a substitute.
- A failed or timed-out rollout returns a distinct host-connection error before credential minting
  and port-forward startup.
- Pin the exact rollout and port-forward subprocess projections in pure unit cases.

### Validation

1. Unit cases prove rollout observation precedes the existing loopback port-forward projection and
   neither command admits an operator-selected namespace, workload, address, or remote port.
2. Warning-clean build, full unit suite, and `prodbox dev check` pass.
3. Live `prodbox cluster reconcile` crosses the Broker host connection and reaches the following
   Vault lifecycle boundary from the current half-built state.

### Remaining Work

None on the sprint-owned surface. The repaired connection carried initialization into the worker,
where Sprint `2.54` owns the later durable-journal refusal.

### Closure

`withBrokerHostConnection` observes `deployment/bootstrap-broker` rollout in the compiled namespace
and supplied kubectl context before it reserves a port, mints a credential, or starts the transport.
The rollout and port-forward command projections are pinned by focused tests (2/2). The rebuilt
installed binary completed `prodbox vault status` through this path in 0.31 seconds and then carried
`prodbox vault init` into the attested secret worker. That worker's “Root initialization journal is
not pristine” result is downstream evidence that the connection performed real work, and the split
journal predicate it exposed is separately owned by Sprint `2.54`.

## Sprint 2.54: One Pristine Journal Has Two Opposite Answers [✅ Done]

**Status**: Done on the code-owned surface — 2026-08-23. Live-proof: pending behind Sprint `2.55`.
**Implementation**: `src/Prodbox/Bootstrap/Broker/ProductionEngine.hs`,
`src/Prodbox/Bootstrap/Broker/ProductionSecretWorker.hs`, and
`src/Prodbox/Bootstrap/Broker/PristineJournal.hs`.
**Deployment qualification**: pending — this changes retained bootstrap-state admission and must be
included in Sprint `6.5`'s current-revision campaign.
**Independent Validation**: table-shaped pure cases over absent, exact pristine, exact reset,
foreign-proof, foreign-binding, and non-pristine phases; source-region proof that both consumers call
the classifier; full unit suite and canonical development gate. The live initialization half is
pending behind Sprint `2.55`.
**Docs updated**: `documents/engineering/vault_doctrine.md`,
`documents/engineering/bootstrap_readiness_doctrine.md`, `DEVELOPMENT_PLAN/README.md`,
`DEVELOPMENT_PLAN/00-overview.md`, and `DEVELOPMENT_PLAN/system-components.md`.

### Objective

Give the controller and its attested one-shot worker one answer to the same retained root-journal
observation. An absent journal and a present journal carrying the exact derived pristine/reset proof
admit preparation; a foreign proof or any progressed/ambiguous phase refuses.

### Deliverables

- Extract one pure classifier over `StoreReadBack RootInitState` and the expected
  `RootInitBinding`; both controller and worker consume it.
- Preserve proof provenance: `RootResetPristine` admits only when its replacement pristine proof is
  the exact one derived for the current storage generation.
- Keep progressed and ambiguous journals fail-closed; no object is deleted, overwritten, or treated
  as absent to recover.
- Add positive/negative table cases and a mutation-sensitive source gate against reintroducing a
  worker-only catch-all `StoreObjectPresent` rejection.

### Validation

1. Pure cases cover absent, exact pristine, exact reset, foreign pristine/reset, and every other
   root-init phase class.
2. Warning-clean build, full unit suite, and `prodbox dev check` pass.
3. Live Vault initialization resumes from retained state and advances beyond preparation without
   deleting the retained root.

### Remaining Work

None on the code-owned surface. Sprint `2.55` owns the independently exposed selector correction;
its live proof then resumes this sprint's pending initialization observation.

### Closure Record

- `classifyPristineJournal` is the sole pure classifier consumed by
  `ProductionEngine.pristineEvidence` and `ProductionSecretWorker.prepareInitialization`.
- Focused Sprint-`2.54` validation passes 2/2; the full unit suite passes 4604/4604; warning-clean
  build and `prodbox dev check` exit 0.
- The rebuilt controller runs with image ID `sha256:9309e970958086bd830a715db86aaba2e13bad439e5d707c4be6ad44ac0533e7`,
  registry digest `sha256:694003de68372998fd6b8fefba61c1f36c5c5d83602979e4e19798078a6c06`,
  and zero restarts. Its `/readyz` refusal names the separate Sprint-`2.55` selector defect, so no
  retained worker was deleted to manufacture this sprint's live proof.

## Sprint 2.55: Controller Self-Observation Selects Its One-Shot Worker [✅ Done]

**Status**: Done and live-proven — 2026-08-23.
**Implementation**: `src/Prodbox/Bootstrap/Broker/KubernetesWorker.hs`,
`charts/bootstrap-broker/templates/_helpers.tpl`, and
`test/unit/BootstrapBrokerProductionBoundary.hs`.
**Deployment qualification**: pending — the changed arm is live-proven locally, but include it in
Sprint `6.5`'s full current-revision campaign.
**Independent Validation**: exact URL-projection cases bind the observer to the chart's controller
selector; live reconcile must make the rebuilt controller Ready while the retained failed worker
still exists, then initialization must advance until the next distinct outcome.
**Docs updated**: `documents/engineering/bootstrap_readiness_doctrine.md`,
`DEVELOPMENT_PLAN/README.md`, `DEVELOPMENT_PLAN/00-overview.md`, and
`DEVELOPMENT_PLAN/system-components.md`.

### Objective

Make controller image self-observation select exactly the controller Deployment Pods. A retained
one-shot worker shares the application name but not the Helm release instance label and must not
enter the controller PodList response.

### Deliverables

- Encode the chart's controller selector as the conjunction of
  `app.kubernetes.io/name=prodbox-bootstrap-broker` and
  `app.kubernetes.io/instance=bootstrap-broker` in the Kubernetes Pod query.
- Pin the URL encoding and its agreement with the chart selector in mutation-sensitive tests.
- Preserve fail-closed multi-controller handling: this correction narrows selection and does not
  teach the parser to choose arbitrarily from multiple matching controller Pods.
- Reconcile and initialize with the retained worker still present; do not delete or relabel it as a
  workaround.

### Validation

1. Focused tests prove the controller query carries both exact selector labels and the chart helper
   renders both labels.
2. Warning-clean build, full unit suite, and `prodbox dev check` pass.
3. Live controller readiness succeeds on the new immutable image while the retained worker remains,
   and `vault init` advances to the next distinct terminal or non-terminal outcome.

### Remaining Work

None. Sprint `2.56` owns the separately exposed expired-owner cleanup refusal.

### Closure Record

- Focused self-observation validation passes 8/8; the full unit command and `prodbox dev check`
  exit 0.
- Live reconcile published local image ID
  `sha256:07fa4d977625155ba2b4edca112f9c44f2fcfb50a5832be345530aad51f9d336`,
  registry digest `sha256:04dd0b276a5e25080176c1bee17e73807632995ea9152e92c5eaa0f42dfe1945`,
  and containerd manifest `sha256:d9399bb54fab1dc0b2500e20bc7242ad772cd75df41b64479c8057ba6bc00782`.
- Deployment generation/revision 4 runs Pod `bootstrap-broker-6c7587f9f8-m447k` Ready with zero
  restarts on that image ID. Retained Pod `bootstrap-secret-worker` remains Failed on the previous
  image and has no instance label. `prodbox vault status` succeeds; the next `vault init` refusal is
  `BootstrapFenceRetireOwnerStillPresent`, owned below.

## Sprint 2.56: A Terminal Worker Is Not A Live Fence Owner [✅ Done]

**Status**: Done and live-proven — 2026-08-23.
**Implementation**: `src/Prodbox/Bootstrap/Broker/KubernetesWorker.hs` and
`src/Prodbox/Bootstrap/Broker/ProductionEngine.hs`.
**Deployment qualification**: pending — terminal-worker cleanup changes the retained bootstrap
recovery path and must be included in Sprint `6.5`'s current-revision campaign.
**Independent Validation**: table-shaped decisions over same-generation terminal/live,
foreign-generation terminal, absent, malformed, and unobservable Pods; exact UID-preconditioned
delete followed by positive absence read-back; live initialization from the retained counterexample.
**Docs to update**: `documents/engineering/bootstrap_readiness_doctrine.md`,
`DEVELOPMENT_PLAN/README.md`, `DEVELOPMENT_PLAN/00-overview.md`, and
`DEVELOPMENT_PLAN/system-components.md`.

### Objective

Let an expired fence retire when its exact worker process is provably terminal, without treating Pod
object presence as process liveness and without deleting a live, foreign, or ambiguously observed
worker.

### Deliverables

- Classify `Succeeded`/`Failed` as terminal only for the queried fence generation; Pending, Running,
  Unknown, and absent phase remain present.
- UID-precondition delete only that terminal same-generation Pod and wait for an exact 404 before
  adapting the observation to `BootstrapFenceOwnerAbsent`.
- Preserve the existing foreign-generation rule: another generation occupying the sole coordinate
  proves queried-generation absence but is never deleted on its behalf.
- Keep malformed identity/generation/status, authorization, transport, deletion, and absence-wait
  failures unobservable and therefore unable to authorize fence retirement.

### Validation

1. Pure cases distinguish terminal same-generation cleanup from every no-delete arm.
2. Focused tests, warning-clean build, full unit suite, and `prodbox dev check` pass.
3. Live reconcile retires the preserved generation-1 fence only after the exact failed worker is
   UID-deleted/read-back absent, then initialization advances to its next distinct outcome.

### Remaining Work

None. Sprint `2.57` owns the separately exposed optional termination-message wire mismatch.

### Closure Record

- Focused Sprint-`2.56` cleanup validation passes 3/3 and the existing Sprint-`2.47` retirement
  validation passes 3/3. The full unit command and warmed `prodbox dev check` exit 0; the first
  cold `dev check` reached the final link and was externally terminated with exit 143, not a test,
  lint, formatter, or compiler failure.
- Live reconcile published local image ID
  `sha256:d35e4758a59221f11339f8d9b81c25726952f1a5d1a30f5918ae27f33eeceb5c`, registry digest
  `sha256:b55e39dccb732213da261e5c16d2e9a4bfd9e01dd1dd905d07aeeab594c5abb2`, and containerd manifest
  `sha256:65b3f7e23eaea6df2628f98d684575a41aec242cc9e33f639ed84d43349f95a6`.
- Deployment generation/revision 5 runs Pod `bootstrap-broker-7c68b5685-5vlgq` Ready with zero
  restarts on that image. The Broker UID-precondition deleted generation-1 worker UID
  `402a2fde-9f17-4668-8e6a-e70c61d3e171`, read the coordinate absent, logged fence-retirement receipt
  `08f276ffbf44fbd79d3a844a575119aa4520b5864b6f7f99daa6e28dfb65f808`, and admitted generation 2
  with worker UID `dc328b94-8adc-4172-9ecc-6cfd6f22e611`. The next refusal is owned below.

## Sprint 2.57: A Failed Worker Without A Termination Message Is Still A Readable Pod [✅ Done]

**Status**: Done on the code-owned surface — 2026-08-23.
**Live-proof**: proven by Sprint `2.58`'s forward run — 2026-08-23.
**Implementation**: `src/Prodbox/Bootstrap/Broker/KubernetesWorker.hs` and
`test/unit/BootstrapBrokerProductionBoundary.hs`.
**Deployment qualification**: pending — the shared worker observation decoder is on the bootstrap
recovery path and must be included in Sprint `6.5`'s current-revision campaign.
**Independent Validation**: pure response decoding over Kubernetes-compliant terminated states with
and without `message`; attestation and exit-binding cases prove omission remains fail-closed; live
initialization must report the next exact worker outcome rather than an unreadable Pod.
**Docs to update**: `documents/engineering/bootstrap_readiness_doctrine.md`,
`DEVELOPMENT_PLAN/README.md`, `DEVELOPMENT_PLAN/00-overview.md`, and
`DEVELOPMENT_PLAN/system-components.md`.

### Objective

Decode the Kubernetes Pod termination contract exactly: `exitCode` is required while the
termination-log `message` is optional. Preserve the distinction between reading a failed Pod and
possessing the exact success receipt required to clean it up.

### Deliverables

- Decode absent `state.terminated.message` as no termination-log receipt rather than rejecting the
  whole Kubernetes response.
- Keep worker attestation fail-closed: a terminal Pod is not Running/ready and cannot attest merely
  because it is now readable.
- Keep lifecycle cleanup fail-closed: an absent receipt cannot equal the cleanup binding's exact
  receipt digest and cannot mint `SecretWorkerProcessExited`.
- Add a response fixture matching the live failed Pod shape and pin both attestation and exit
  observations without carrying response-body values into operator-visible decode errors.

### Validation

1. Focused pure cases prove an omitted termination message yields a readable terminal Pod but never
   an attestation or receipt-bound exit success.
2. Warning-clean build, full unit suite, and `prodbox dev check` pass.
3. Live reconcile reports the worker's next distinct exact outcome and never reports the valid Pod
   body as `the response is not a readable Pod`.

### Remaining Work

None on the code-owned surface. Sprint `2.58` owns the separately exposed controller PodList
cardinality refusal.

### Closure Record

- `ContainerTerminationWire` carries `Maybe Text`; Kubernetes may omit the termination-log message,
  while `validateExitedPod` requires `Just` the exact receipt digest before returning exit evidence.
- The focused live-shaped case passes 1/1. The full unit command passes 4609 main cases plus all
  authority-admission/authentication/transport suites, and warmed `prodbox dev check` passes.
- Live reconcile published image ID
  `sha256:9c74f2eb23b674ea1d7df115924b6146e489e0081ab301936ef30a932955d6e0`, registry digest
  `sha256:6fb3ea788cf939be92052f7083fdbb23bf55d01d14c12a9f1d01add19de6b37f`, and containerd manifest
  `sha256:2730dd338385b2097d20b217bd8bcc5812628b2ae5f51850004e80430113131a`. Deployment
  generation/revision 6 runs that image with zero restarts, but readiness stops earlier at the
  Sprint-`2.58` selector counterexample rather than reaching worker attestation.
- Sprint `2.58`'s successor image then reached the same failed worker and reported four exact
  `worker phase mismatch` arms, never `the response is not a readable Pod`; this closes the pending
  live axis.

## Sprint 2.58: Terminal Controller Pods Do Not Count As Live Self-Observation Candidates [✅ Done]

**Status**: Done and live-proven — 2026-08-23.
**Implementation**: `src/Prodbox/Bootstrap/Broker/KubernetesWorker.hs` and
`test/unit/BootstrapBrokerProductionBoundary.hs`.
**Deployment qualification**: pending — controller self-readiness is a production process-topology
surface and must be included in Sprint `6.5`'s current-revision campaign.
**Independent Validation**: table-shaped PodList responses with one live plus terminal history,
multiple live candidates, deleting candidates, malformed items, and no live candidate; live rollout
must make the current controller Ready without deleting terminal evidence manually.
**Docs to update**: `documents/engineering/bootstrap_readiness_doctrine.md`,
`DEVELOPMENT_PLAN/README.md`, `DEVELOPMENT_PLAN/00-overview.md`, and
`DEVELOPMENT_PLAN/system-components.md`.

### Objective

Make controller self-observation ask for exactly one live controller rather than exactly one Pod
object across the Deployment's retained terminal history.

### Deliverables

- Exclude only Pods whose observed phase is positively `Succeeded` or `Failed` before enforcing the
  one-controller cardinality rule.
- Keep Pending, Running, Unknown, and deleting Pods in the candidate set; a sole Pending/Unknown or
  deleting candidate then fails its existing exact state check rather than being inferred absent.
- Preserve whole-list fail-closed decoding: one malformed Pod item makes the observation
  unobservable, and two nonterminal controller candidates remain ambiguous.
- Pin the live counterexample with one Running current Pod plus two terminal historical Pods and no
  manual deletion or label mutation.

### Validation

1. Focused pure cases admit exactly one live candidate alongside terminal history and refuse every
   ambiguous/unobservable variant.
2. Warning-clean build, full unit suite, and `prodbox dev check` pass.
3. Live reconcile makes the current immutable controller Ready while retained terminal controller
   Pods remain, then initialization advances to the next exact worker outcome.

### Remaining Work

None. Sprint `2.59` owns the separately exposed worker Lease-read capability mismatch.

### Closure Record

- Focused self-observation validation passes 10/10; the full unit command passes 4611 main cases
  plus all authority-admission/authentication/transport suites; `prodbox dev check` exits 0.
- Live reconcile published image ID
  `sha256:7ed35b256003eec961b9f7e893d611139db0a61dc37170c1b073b1fcb510976a`, registry digest
  `sha256:1149cd82f7904d9d30c96cf587c2d522043f56524c4bb2f06ba1904018030448`, and containerd manifest
  `sha256:78f9a943dbeb6e249033affeac82d39eb579eb3a26dfdf51eafb95abebe5a584`.
- Deployment generation/revision 7 runs Pod `bootstrap-broker-66cdf47645-rhw77` Ready with zero
  restarts on that image while retained controller Pods `bootstrap-broker-7c68b5685-5dks5` and
  `bootstrap-broker-7c68b5685-5vlgq` remain `Succeeded`. The supported initialization path retired
  fence generation 2 with absence receipt `1f63524a…`, launched generation-3 worker UID
  `b6d29452-a78f-49ff-9914-3b9c40db1282`, and reached the next refusal owned below.

## Sprint 2.59: The Worker Can Read The Exact Fence It Must Revalidate [✅ Done]

**Status**: Done and live-proven — 2026-08-23.
**Implementation**: `charts/bootstrap-broker/templates/tokenreview-rbac.yaml` and chart/RBAC unit
validation.
**Deployment qualification**: pending — worker effect authorization is a production capability
wiring surface and must be included in Sprint `6.5`'s current-revision campaign.
**Independent Validation**: rendered Role rules prove the worker may get exactly its fixed Pod and
the named fence Lease but cannot mutate either resource or access Secrets/TokenReviews; live
initialization must cross worker effect authorization to the next exact outcome.
**Docs to update**: `documents/engineering/bootstrap_readiness_doctrine.md`,
`DEVELOPMENT_PLAN/README.md`, `DEVELOPMENT_PLAN/00-overview.md`, and
`DEVELOPMENT_PLAN/system-components.md`.

### Objective

Make the worker's Kubernetes capability agree with its mandatory per-effect fence protocol: it must
observe the one exact Lease whose binding it revalidates, without gaining any lifecycle mutation.

### Deliverables

- Add `get` on resource name `bootstrap-broker-fence` in the worker ServiceAccount's namespaced Role.
- Keep controller-only `create`/`update` Lease verbs out of the worker binding and preserve its exact
  fixed-Pod `get` rule.
- Pin the rendered role and negative capability set in mutation-sensitive chart tests.
- Preserve authorization failure as fail-closed; this sprint does not weaken or bypass the
  per-effect Lease check.

### Validation

1. Focused chart/RBAC cases prove the exact positive rule and forbidden mutation/secret/tokenreview
   capabilities.
2. Warning-clean build, full unit suite, and `prodbox dev check` pass.
3. Live reconcile admits the worker's exact fence revalidation and advances initialization to its
   next distinct outcome.

### Remaining Work

None. Sprint `2.60` owns the separately exposed missing public recovery command.

### Closure Record

- The rendered worker Role grants `get` on only Pod `bootstrap-secret-worker` and Lease
  `bootstrap-broker-fence`; it grants no create/update/delete, Secret, TokenReview, exec, or attach
  capability. Focused rendered-YAML validation passes 1/1, the full unit command and
  `prodbox dev check` exit 0, and the live installed Role has the same two exact rules.
- Live reconcile retained controller image ID `sha256:7ed35b25…`, crossed the worker's mandatory
  durable-fence and Lease observations, and reached Vault `/sys/init`. The broker then persisted
  `RootInitializationAmbiguous`, retired generation-3 with worker-absence receipt `8a146171…`, and
  reported initialized/sealed Vault with no durable recovery custody. That later fail-closed state
  is Sprint `2.60`, not an RBAC refusal.

## Sprint 2.60: The Proven-Pristine Ambiguity Reset Has A Public Client [✅ Done]

**Status**: Done on the code-owned surface — 2026-08-23. Live-proof: pending behind Sprint `2.61`.
**Implementation**: `src/Prodbox/CLI/Command.hs`, `src/Prodbox/CLI/Spec.hs`,
`src/Prodbox/CLI/Vault.hs`, and CLI/parser validation.
**Deployment qualification**: pending — the storage-generation replacement and resumed bootstrap
must be included in Sprint `6.5`'s current-revision campaign.
**Independent Validation**: parser/help/command-surface cases pin an explicit confirmation-gated
leaf; broker client projection pins the existing typed recovery route; a live run must prove the
old ambiguous binding is replaced before initialization can resume.
**Docs to update**: `documents/engineering/cli_command_surface.md`,
`documents/engineering/vault_doctrine.md`, `DEVELOPMENT_PLAN/README.md`,
`DEVELOPMENT_PLAN/00-overview.md`, and `DEVELOPMENT_PLAN/system-components.md`.

### Objective

Make the broker's already-implemented proven-pristine ambiguity recovery reachable through the
supported CLI. The command never retries `/sys/init` against the ambiguous generation: it invokes
the exact typed reset, requires replacement-generation read-back, and only then allows normal
bootstrap to start a new transaction.

### Deliverables

- Add one explicit `prodbox vault reset-ambiguous-initialization --yes` leaf that refuses without
  confirmation and invokes only `BrokerVaultResetAmbiguousInitialization`.
- Query broker status first and admit the command only when initialization is ambiguous; bind the
  request to the exact observed storage generation.
- Preserve the broker's proof boundary: the host supplies no pristine assertion, replacement
  generation, Pod name, storage path, or deletion target.
- Pin parser, prerequisite, help/command-registry, and handler routing so no direct Kubernetes or
  filesystem reset can be substituted.

### Validation

1. Focused cases prove confirmation, exact route/generation binding, command metadata, and the
   absence of operator-selected reset coordinates.
2. Warning-clean build, full unit suite, and `prodbox dev check` pass.
3. Live reset reports success only after the old ambiguous storage generation is replaced and
   read back pristine; subsequent reconcile initializes, unseals, and completes baseline custody.

### Remaining Work

None on the code-owned surface. Sprint `2.61` owns the independently exposed recovery-connection
readiness deadlock; its live proof resumes this command unchanged.

### Closure Record

- `prodbox vault reset-ambiguous-initialization --yes` queries the authenticated Broker status,
  refuses outside ambiguity, binds the action to the observed storage generation, and invokes only
  `BrokerVaultResetAmbiguousInitialization`. Omitting `--yes` refuses before broker mutation.
- Focused parser/confirmation and generated command-registry cases pass 5/5; the full unit command
  passes 4616 main cases plus 27/33/29 authority suites; warmed `prodbox dev check` exits 0.
- The confirmed live invocation reached only the shared Deployment-rollout barrier and timed out.
  The running Broker was NotReady exactly because ambiguity is fail-closed, so the route did not
  execute and no reset target changed. Sprint `2.61` owns that later transport admission defect.

## Sprint 2.61: Ambiguity Recovery Reaches A Live But Deliberately NotReady Broker [✅ Done]

**Status**: Done and live-proven — 2026-08-23.
**Implementation**: `src/Prodbox/Bootstrap/Broker/PortForward.hs`,
`src/Prodbox/CLI/Vault.hs`, and focused connection-boundary validation.
**Deployment qualification**: pending — the recovery connection and storage replacement must be
included in Sprint `6.5`'s current-revision campaign.
**Independent Validation**: pure subprocess/source-region cases prove normal Broker calls retain
the exact Deployment-rollout barrier and only the ambiguity-reset handler selects the recovery
connection; live reset must cross liveness without claiming readiness.
**Docs to update**: `documents/engineering/bootstrap_readiness_doctrine.md`,
`documents/engineering/vault_doctrine.md`, `documents/engineering/cli_command_surface.md`,
`DEVELOPMENT_PLAN/README.md`,
`DEVELOPMENT_PLAN/00-overview.md`, and `DEVELOPMENT_PLAN/system-components.md`.

### Objective

Break the recovery deadlock without weakening ordinary readiness. The one route whose purpose is
to leave `RootInitializationAmbiguous` may connect to a running Broker proven by its authenticated
`/healthz`; every other host client still waits for the exact Deployment rollout before credential
minting and port-forward startup.

### Deliverables

- Add a closed recovery-only connection combinator that skips only the Deployment-readiness barrier
  and retains loopback reservation, TokenRequest authentication, Service port-forwarding,
  authenticated health proof, bracketed cleanup, and bounded retry.
- Select it only from `runBrokerVaultResetAmbiguousInitialization`; do not expose a Boolean or
  caller-selectable readiness mode.
- Preserve the normal `withBrokerHostConnection` sequence and exact subprocess projection for every
  status/init/unseal/seal/reconcile/rotation/PKI call.
- Pin the routing distinction and ensure neither connection widens namespace, Service, address,
  named port, audience, or credential scope.

### Validation

1. Focused cases prove the recovery combinator has no rollout subprocess while the normal path is
   unchanged, and the reset handler alone uses recovery liveness.
2. Warning-clean build, full unit suite, and `prodbox dev check` pass.
3. The retained live ambiguity resets through the authenticated loopback route, reads back a new
   pristine generation, and normal reconcile completes initialization/unseal/baseline.

### Remaining Work

None. Sprint `2.62` owns the separately exposed physical reset refusal.

### Closure Record

- The closed `withBrokerHostRecoveryConnection` skips only Deployment rollout and retains exact
  loopback Service forwarding, TokenRequest authentication, authenticated `/healthz`, bounded
  retry, and cleanup; only the ambiguity-reset handler uses it.
- Focused source/projection validation passes 2/2, the full unit command passes 4618 main cases plus
  27/33/29 authority suites, and `prodbox dev check` exits 0.
- The confirmed live reset reached `/v1/bootstrap/vault/ambiguous-init/reset` in 1.9 seconds rather
  than timing out on rollout. Its later 503 is `EnginePhysicalCallRefused`, proving the transport
  arm live and exposing Sprint `2.62` below.

## Sprint 2.62: The Reset Boundary Names Its Failure Stage Without Payloads [✅ Done]

**Status**: Done and live-proven — 2026-08-23.
**Implementation**: `src/Prodbox/Bootstrap/Broker/KubernetesWorker.hs`,
`src/Prodbox/Bootstrap/Broker/ProductionEngine.hs`, and
`src/Prodbox/Bootstrap/Broker/EngineAdapter.hs`.
**Deployment qualification**: pending — include the reset diagnostic and recovery sequence in
Sprint `6.5`'s current-revision campaign.
**Independent Validation**: a closed payload-free reset failure algebra distinguishes identity,
controller, scale, absence, Pod create/status/validation, cleanup, identity-read-back, and scale-up;
live recovery must name and then cross the exact refusing arm.
**Docs to update**: `documents/engineering/bootstrap_readiness_doctrine.md`,
`documents/engineering/vault_doctrine.md`, `DEVELOPMENT_PLAN/README.md`,
`DEVELOPMENT_PLAN/00-overview.md`, and `DEVELOPMENT_PLAN/system-components.md`.

### Objective

Make the destructive recovery boundary diagnosable without publishing Kubernetes bodies or
controller-authored bindings. Every failure names its closed stage and, where the only useful
payload is an HTTP refusal, its numeric status; the public response remains generic.

### Deliverables

- Replace reset-path `Either Text` collapse with a closed `VaultStorageResetFailure` whose renderer
  contains only constructor names and numeric HTTP status where applicable.
- Carry that renderer into the broker diagnostic only for the physical ambiguity-reset route; keep
  the HTTP response body generic and every other boundary detail redacted.
- Pin all reset stages and prove arbitrary Kubernetes response bytes cannot reach logs or output.
- Preserve the fixed reset name, PVC identity/proof annotations, bounded resources, UID deletion,
  and absence read-back while the new diagnostic identifies the next separately owned correction.

### Validation

1. Focused cases cover every failure constructor, diagnostic redaction, and the route-specific
   renderer boundary.
2. Warning-clean build, full unit suite, and `prodbox dev check` pass.
3. A rebuilt live Broker preserves the generic public response while emitting one closed
   payload-free stage/status that is sufficient to register the next counterexample.

### Remaining Work

None. Sprint `2.63` owns the separately exposed omitted-zero Scale decoder correction.

### Closure Record

- `VaultStorageResetFailure` covers all 18 identity/controller/scale/Pod/cleanup/read-back stages;
  its only payloads are numeric HTTP statuses. Only the physical ambiguity-reset adapter renders
  the algebra, and the public HTTP response remains generic.
- Focused constructor/redaction validation passes 2/2, the full unit command passes 4620 main cases
  plus 27/33/29 authority suites, and `prodbox dev check` exits 0 with no HLint findings and a
  warning-clean all-target build.
- Reconcile deployed image ID `sha256:6e475d76…`; the confirmed reset returned only
  `{"status":"boundary-unavailable"}` and the Broker logged only
  `vault-reset=scale-down-unavailable`. The read-only Scale response was exact object identity plus
  `"spec": {}` at desired count zero, exposing Sprint `2.63` without leaking the body through the
  diagnostic.

## Sprint 2.63: Kubernetes Scale Omission Means Zero [✅ Done]

**Status**: Done and live-proven — 2026-08-23.
**Implementation**: `src/Prodbox/Bootstrap/Broker/KubernetesWorker.hs` and focused Scale-wire
validation in `test/unit/Main.hs`.
**Deployment qualification**: pending — include zero-scale recovery and the complete resumed
bootstrap in Sprint `6.5`'s current-revision campaign.
**Independent Validation**: pure Scale-response cases prove exact identity/resource-version
validation while accepting both an explicit positive replica count and Kubernetes' omitted-zero
encoding; a retained live reset proves the same native path progresses beyond scale-down.
**Docs to update**: `documents/engineering/bootstrap_readiness_doctrine.md`,
`documents/engineering/vault_doctrine.md`, `DEVELOPMENT_PLAN/README.md`,
`DEVELOPMENT_PLAN/00-overview.md`, and `DEVELOPMENT_PLAN/system-components.md`.

### Objective

Decode Kubernetes' `autoscaling/v1` Scale wire as the API defines it: a missing
`spec.replicas` field has the Go `omitempty` zero value and is not malformed. Preserve the strict
object identity/resource-version checks and the exact read-back comparison before advancing the
destructive reset program.

### Deliverables

- Default only an omitted `spec.replicas` to zero; reject a malformed, negative, wrong-kind,
  wrong-name, wrong-namespace, or unversioned Scale response as before.
- Pin pure explicit-positive and omitted-zero response cases through an exported observation helper
  consumed by the production decoder rather than source-text matching.
- Keep the scale update as an exact resource-versioned `PUT`, and require its decoded read-back to
  equal the requested replica count.
- Resume the retained confirmed reset and register any later distinct counterexample before
  correcting it.

### Validation

1. Focused Scale-wire cases prove omitted zero, explicit positive, and strict refusal arms.
2. Warning-clean build, full unit suite, and `prodbox dev check` pass.
3. The retained live reset crosses scale-down and reaches its next exact terminal outcome; if the
   reset completes, normal reconcile initializes, unseals, and completes baseline custody.

### Remaining Work

None. Sprint `2.64` owns the separately exposed applied-initialization ambiguity diagnostic.

### Closure Record

- `ScaleWire` gives only an omitted `spec.replicas` the API's zero-value meaning; explicit positive
  values remain intact and malformed, negative, wrong-kind/name/namespace, or unversioned responses
  remain refusals. Production decoding and focused tests share the exported pure observation helper.
- Focused Scale-wire validation passes 3/3, the full unit command passes 4623 main cases plus
  27/33/29 authority suites, and `prodbox dev check` exits 0 with no HLint findings and a
  warning-clean all-target build.
- Reconcile deployed image ID `sha256:0e975c27…`; the confirmed reset crossed scale-down, ran and
  removed the fixed reset Pod, read back controller identity, scaled up, and returned mutation
  receipt `9a51bcc9…` for new pristine generation `vault-reset-5cfd3662…`. The following normal
  reconcile reached Vault initialization and failed closed with `EngineInitializationAmbiguous`,
  exposing Sprint `2.64` rather than reopening this decoder.

## Sprint 2.64: Applied Initialization Ambiguity Names Its Failure Class [✅ Done]

**Status**: Done — closed and live-proven 2026-08-24.
**Implementation**: `src/Prodbox/Bootstrap/Broker/ProductionSecretWorker.hs`,
`src/Prodbox/Bootstrap/Broker/SecretWorker.hs`,
`src/Prodbox/Bootstrap/Broker/ProductionSecretWorkerBoundary.hs`,
`src/Prodbox/Bootstrap/Broker/Engine.hs`, `src/Prodbox/Bootstrap/Broker/EngineAdapter.hs`, and
focused validation under `test/unit/`.
**Deployment qualification**: pending — include the diagnosed initialization ambiguity and its
eventual recovery in Sprint `6.5`'s current-revision campaign.
**Independent Validation**: pure classification and wire/engine propagation cases prove every
Vault HTTP failure class is payload-free, survives the one-shot worker boundary, leaves the durable
root journal unchanged, and is rendered only at the protected Broker diagnostic boundary; a retained
live reset/reconcile cycle identifies the observed class.
**Docs to update**: `documents/engineering/bootstrap_readiness_doctrine.md`,
`documents/engineering/vault_doctrine.md`, `DEVELOPMENT_PLAN/README.md`,
`DEVELOPMENT_PLAN/00-overview.md`, and `DEVELOPMENT_PLAN/system-components.md`.

### Objective

Preserve why an initialization call became applied-without-response after Vault's initialized
read-back, without retaining or publishing a transport exception, Vault response body, encrypted
shares, token material, or prepared-recipient data. The diagnostic must name the exact closed
failure class before any separately registered behavioral correction is attempted.

### Deliverables

- Introduce a closed payload-free initialization-ambiguity cause that distinguishes a pre-call
  already-initialized observation from connection, timeout, numeric HTTP status, and response-decode
  failure after the initialization request.
- Carry that cause through the one-shot worker durable result and engine outcome while leaving the
  serialized `InitAmbiguity` root-journal shape unchanged; pin retained result compatibility where
  the existing wire contract requires it.
- Render the closed cause only in the protected Broker diagnostic for the initialization-ambiguity
  route. Keep the public response generic and prove arbitrary exception/body bytes cannot reach it
  or the diagnostic.
- Deploy the rebuilt Broker, use only the confirmed `prodbox` reset and reconcile surfaces to
  reproduce initialization, and register the exact next correction only after the cause is observed.

### Validation

1. Focused cases cover every cause constructor, durable worker/engine propagation, redaction, and
   unchanged root-journal encoding.
2. Warning-clean build, full unit suite, and `prodbox dev check` pass.
3. A rebuilt live Broker emits one closed payload-free initialization-ambiguity cause while the
   public response remains generic; the cause is sufficient to scope the next sprint.

### Remaining Work

None. Sprint `2.65` owns the separately registered response-decoder correction exposed by the live
cause.

### Closure Record

- `InitializationAmbiguityCause` distinguishes already-initialized-before-call, connection,
  timeout, numeric HTTP status, response decoding, and retained unclassified results without
  storing any exception or response payload. The classified durable constructor is appended after
  the retained constructors; the legacy ambiguity result remains byte-for-byte CBOR `[129,3]`, and
  the root `InitAmbiguity` journal is unchanged.
- The cause crosses the production one-shot boundary and engine. Only the initialization route's
  protected diagnostic appends the safe cause name; its loopback public response remains exactly
  `409 {"status":"state-conflict"}`. Focused validation passes 3/3, the full unit command passes
  4626 main cases plus 27/33/29 authority suites, the warning-clean all-target build passes, and
  `prodbox dev check` exits 0.
- Reconcile deployed local image ID `sha256:567130c4…` and registry digest
  `sha256:e6ead3a1…` in a Ready zero-restart Broker Pod. After the confirmed reset, the normal
  reconcile returned the same generic conflict while the protected Broker log named
  `initialization-cause=response-decode-failure`; `vault status` proves initialized/sealed with no
  recovery custody. That exact counterexample registers Sprint `2.65` rather than weakening the
  diagnostic or resetting again without a decoder correction.

## Sprint 2.65: Canonical Dual-Encoded Vault Initialization Response [✅ Done]

**Status**: Done — closed and live-proven 2026-08-24.
**Implementation**: `src/Prodbox/Bootstrap/Broker/VaultWire.hs` and focused validation under
`test/unit/BootstrapBrokerFoundation.hs`.
**Deployment qualification**: pending — include the applied-without-response counterexample and
the corrected initialization/custody path in Sprint `6.5`'s current-revision campaign.
**Independent Validation**: pure response-decoder fixtures prove exact canonical dual-encoding
agreement, strict field/family refusal, redaction, and immediate projection into opaque custody;
the retained live reset/reconcile cycle proves the real Vault response reaches durable custody.
**Docs to update**: `documents/engineering/bootstrap_readiness_doctrine.md`,
`documents/engineering/vault_doctrine.md`, `DEVELOPMENT_PLAN/README.md`,
`DEVELOPMENT_PLAN/00-overview.md`, and `DEVELOPMENT_PLAN/system-components.md`.

### Objective

Decode Vault's complete documented initialization response without treating its redundant `keys`
projection as a second secret source and without weakening the Broker's strict secret-safe wire
boundary. The two wire projections must prove they name the same encrypted bytes before only the
opaque base64-derived custody values survive parsing.

### Deliverables

- Admit `keys` beside `keys_base64`, or `recovery_keys` beside `recovery_keys_base64`, only as an
  exact equal-length pointwise canonical hexadecimal/base64 dual encoding of the same encrypted
  share bytes. Reject a missing half, malformed encoding, disagreement, mixed Shamir/recovery
  families, or any other field.
- Discard the decoded hexadecimal projection inside the parser and expose only the existing opaque,
  redacting `PgpEncryptedShare` values plus opaque burn-token ciphertext; add no printable or
  durable raw-share constructor.
- Pin the documented Vault-shaped response, every refusal arm, and `Show` redaction in pure tests;
  keep the public initialization response and Sprint `2.64` diagnostic algebra unchanged.
- Use the confirmed reset surface once, resume normal reconcile, and require encrypted response
  write/read-back, final unlock-bundle promotion, unseal, and baseline custody to reach their next
  exact terminal outcome. Register any distinct counterexample before correcting it.

### Validation

1. Focused decoder cases prove exact Shamir and recovery dual encodings, canonicality/equality,
   strict unexpected-field/family refusal, and redaction.
2. Warning-clean build, full unit suite, and `prodbox dev check` pass.
3. A rebuilt live Broker crosses initialization response decoding into durable encrypted custody;
   the retained reset/reconcile cycle reaches its next exact terminal result.

### Remaining Work

None. Sprint `2.66` owns the separately registered post-unseal consumer-ordering counterexample.

### Closure Record

- `EncryptedVaultInitResponse` accepts exactly one complete Shamir or recovery family. Both arrays
  must be non-empty and equal in length; lowercase hexadecimal and canonical base64 must decode
  pointwise to the same encrypted bytes. Missing halves, malformed/case-noncanonical input,
  disagreement, mixed families, and additional fields refuse. The redundant hex projection is
  discarded inside the parser; only existing opaque redacting values survive.
- Focused decoder validation passes 2/2, the warning-clean all-target build passes, the full unit
  command passes 4627 main cases plus 27/33/29 authority suites, and `prodbox dev check` exits 0
  with no HLint findings. The governed engineering docs state the same strict wire boundary.
- Reconcile built local image ID `sha256:7eac19fd…`, published registry digest
  `sha256:efaf8f61…`, and rolled Deployment generation 11 to one Ready zero-restart Pod. After the
  confirmed reset receipt `9a51bcc9…`, initialization returned recovery-custody digest
  `3c90f4f9…` for `vault-reset-37bbd69a…`, proving encrypted response decoding, persistence, and
  final-bundle promotion. The following unseal applied — status is initialized, unsealed, and
  custody-durable — but its later consumer observation returned generic `boundary-unavailable`,
  which is Sprint `2.66` rather than a decoder or worker-result failure.

## Sprint 2.66: Post-Unseal Handoff Follows Authority Readiness [✅ Done]

**Status**: Done on the code-owned surface — opened and closed 2026-08-24; deployed live proof
reached baseline and is pending exact handoff behind Sprint `2.67`.
**Implementation**: `src/Prodbox/Bootstrap/Broker/Routes.hs`,
`src/Prodbox/Bootstrap/Broker/Engine.hs`, `src/Prodbox/Bootstrap/Broker/Client.hs`,
`src/Prodbox/CLI/Vault.hs`, `src/Prodbox/CLI/Rke2.hs`, and focused validation under `test/unit/`.
**Deployment qualification**: pending — include the applied-unseal/consumer-absent
counterexample and corrected transition order in Sprint `6.5`'s current-revision campaign.
**Independent Validation**: the pure engine and route fixtures prove unseal and baseline close
without consumer access, a fake ready Authority completes and read-backs the exact handoff, and
the native Plan / Apply step table places the transition after Authority readiness.
**Docs to update**: `documents/engineering/bootstrap_readiness_doctrine.md`,
`documents/engineering/vault_doctrine.md`, `DEVELOPMENT_PLAN/README.md`,
`DEVELOPMENT_PLAN/00-overview.md`, and `DEVELOPMENT_PLAN/system-components.md`.

### Objective

Remove the bootstrap-order cycle without weakening the observed-handoff invariant. Unseal closes
when its attested one-shot worker receipt is validated, baseline closes when its root-session
receipt is validated, and the Broker performs the durable consumer acceptance/read-back only from
an explicit graph transition after Lifecycle Authority has reached its rollout barrier.

### Deliverables

- Make the unseal route return its exact validated mutation receipt without contacting the
  post-unseal consumer, and make baseline reconciliation stop requiring a handoff that cannot yet
  exist. Preserve generation binding, fencing, idempotency, and generic refusal behavior.
- Add one closed, fixed-coordinate Broker mutation for post-unseal handoff. It resolves the durable
  root custody binding internally, drives the existing observation-only handoff state machine, and
  succeeds only after Lifecycle Authority acceptance is observed back with the exact generation,
  consumer, and digest.
- Add an explicit native reconcile step after `StepLifecycleAuthorityChartReady`; keep narration
  and execution projected from the same table. The step carries no password/share bytes and cannot
  be selected before consumer readiness.
- Deploy the rebuilt Broker and resume normal reconcile against the already-unsealed,
  custody-durable generation. Prove baseline, Authority rollout, and exact handoff read-back advance
  in that order without reinitializing Vault.

### Validation

1. Focused cases prove unseal never calls the handoff boundary, baseline no longer requires prior
   handoff, the separate route resumes every handoff journal phase, and wrong generation/consumer/
   read-back evidence refuses.
2. Warning-clean build, full unit suite, and `prodbox dev check` pass.
3. A rebuilt live Broker and retained reconcile reach observed handoff after Authority readiness
   without reinitializing Vault; status names the same durable generation and `handoff_observed`.

### Remaining Work

None on Sprint `2.66`'s code-owned surface. Sprint `2.67` owns the separately observed baseline
physical refusal that precedes Lifecycle Authority deployment and exact handoff qualification.

### Closure Record

- `BrokerPostUnsealHandoffReconcile` is the seventeenth fixed Broker route and resolves only the
  durable exact-generation custody binding. Unseal returns its attested worker receipt without a
  consumer call; baseline closes on its root/provisioner receipt; the separate route retains the
  existing accept/observe handoff state machine.
- `StepPostUnsealHandoff` follows `StepLifecycleAuthorityChartReady` in the same compiled native
  component projection and is that component's exact terminal readiness receipt. Plan narration,
  Apply dispatch, ordering assertions, and both RKE2 goldens derive from that table.
- Focused sequencing, early-refusal, route, admission, and plan cases pass. The warning-clean
  all-target build passes; the full unit command passes 4629 main cases plus 27/33/29 authority
  suites; the heap-bounded canonical `prodbox dev check` exits 0 with no HLint findings. Its first
  default invocation had already passed policy/format/lint before host memory pressure terminated
  the child build; the same build also passes independently with `-Werror -j1`.
- Reconcile built local image ID `sha256:31d050471ff1…`, published and re-pulled registry digest
  `sha256:5171b92b6905…`, and rolled the Broker to the immutable
  `prodbox-3349a232b3454fb3be77b2f68919904f` tag. Unseal returned its exact receipt through that
  image and the next call was baseline, not handoff. Baseline then returned the distinct Sprint
  `2.67` HTTP 409; retained status proves generation `vault-reset-37bbd69a…` initialized,
  unsealed, custody-durable, root-session-active, and handoff-unobserved.

## Sprint 2.67: Baseline Physical Refusal Names Its Closed Stage [✅ Done]

**Status**: Done on the code-owned surface — opened and closed 2026-08-24; its deployed correction
crossed the physical bypass and exact baseline/handoff live proof remains pending behind Sprint
`2.68`'s distinct PGP refusal.
**Live-proof**: pending behind Sprint `2.68`.
**Implementation**: `src/Prodbox/Bootstrap/Broker/Engine.hs`,
`src/Prodbox/Bootstrap/Broker/ProductionEngine.hs`,
`src/Prodbox/Bootstrap/Broker/EngineAdapter.hs`, and focused validation under `test/unit/`.
**Deployment qualification**: pending — resume the retained active root session through exact
baseline completion, Lifecycle Authority readiness, and handoff read-back; include the result in
Sprint `6.5`'s current-revision campaign.
**Independent Validation**: pure/physical fixtures prove every root/provisioner physical refusal
maps to one closed payload-free stage, only the protected baseline-route diagnostic renders that
stage, the public response stays generic, and the corrected exact step resumes idempotently from
the retained journal.
**Docs to update**: `documents/engineering/bootstrap_readiness_doctrine.md`,
`documents/engineering/vault_doctrine.md`, `DEVELOPMENT_PLAN/README.md`,
`DEVELOPMENT_PLAN/00-overview.md`, and `DEVELOPMENT_PLAN/system-components.md`.

**Live diagnosis (2026-08-24)**: the classifier deployed at local image ID
`sha256:39e202ed…` / registry digest `sha256:2ca464ce…`; the public route retained its generic HTTP
409 while the protected log named `baseline-stage=await-generated-root-ciphertext`. Source
projection confirms `PhysicalAwaitGeneratedRootCiphertext` advertises
`SecretWorkerCompleteGeneratedRoot`, but the generated-root workflow called `runPhysical`
directly. Production's deliberate secret-worker bypass guard is therefore the refusal; no Vault
response, token, accessor, share, or worker result is implicated.

### Objective

Turn the live baseline route's generic physical refusal into a secret-safe, closed, actionable
stage observation, then correct the exact refusing root/provisioner transition and resume the same
durable session. Preserve the generic public response, opaque token/share material, exact
generation binding, root-accessor cleanup, fencing, and independent read-back requirements.

### Deliverables

- Define a closed payload-free baseline physical stage covering every root-session and provisioner
  physical call. Attach it at the call site so the protected baseline-route diagnostic can name
  the stage without rendering a Vault body, token, accessor, share, or free-form boundary detail.
- Keep every non-baseline route and every public refusal body unchanged. Exhaustive matching must
  make a newly added physical step fail compilation until it receives an authored stage.
- Route `PhysicalAwaitGeneratedRootCiphertext` through `runAuthorizedSecretWorkerPhysical` under
  the same `BootstrapVaultSubmitGenerateRootShare` effect and mutation attempt used to mint the
  PGP-bound originating permit. The direct physical interpreter remains fail-closed. Add a
  regression for the retained state and its idempotent retry.
- Rebuild and deploy the Broker, resume normal reconcile, and require baseline completion,
  Lifecycle Authority readiness, and exact post-unseal handoff read-back for the same storage
  generation.

### Validation

1. Focused cases prove exhaustive stage classification, protected diagnostic rendering, generic
   wire refusal, and the exact retained-session correction including retry/read-back behavior.
2. Warning-clean build, full unit suite, and `prodbox dev check` pass.
3. A rebuilt live Broker resumes the retained root session without reinitializing Vault, allocates
   and retires the generated-root completion worker, and crosses the former direct-physical bypass.

### Remaining Work

None on the code-owned surface. Sprint `2.68` owns the distinct PGP refusal exposed after the
corrected worker completed.

### Closure Record

- The closed baseline classifier contains 16 unique exhaustive stage labels. Only the protected
  baseline diagnostic renders one; public HTTP responses and unrelated route diagnostics remain
  generic and secret-free.
- `PhysicalAwaitGeneratedRootCiphertext` now runs through
  `runAuthorizedSecretWorkerPhysical` under `BootstrapVaultSubmitGenerateRootShare`; production's
  direct physical interpreter continues to refuse that secret-worker constructor.
- The warning-clean all-target build, focused retained-session/response-loss cases, full unit
  command (**4630** primary cases plus **27/33/29** authority suites), documentation lint, and the
  heap-bounded canonical `prodbox dev check` all pass.
- The corrected live image is local ID `sha256:eb617339…`, registry digest
  `sha256:d8699b89…`, and Broker Deployment generation 14 with zero restarts. It retired the
  generated-root worker with exact absence receipt `377ecaf4…`, then exposed Sprint `2.68`'s
  distinct PGP state conflict on the same `vault-reset-37bbd69a…` generation.

## Sprint 2.68: A Closed PGP Refusal Still Reports Only That PGP Refused [✅ Done]

**Status**: Done and correction live-proven — opened and closed 2026-08-24.
**Implementation**: `src/Prodbox/Bootstrap/Broker/PgpBoundary.hs`,
`src/Prodbox/Bootstrap/Broker/Engine.hs`,
`src/Prodbox/Bootstrap/Broker/EngineAdapter.hs`, and focused validation under `test/unit/`.
**Deployment qualification**: pending — resume the retained active root session through exact
baseline completion, Lifecycle Authority readiness, and handoff read-back; include the result in
Sprint `6.5`'s current-revision campaign.
**Independent Validation**: pure fixtures exhaust the closed `PgpBoundaryError` algebra, prove
only the protected baseline route renders its stable payload-free label, keep the public response
generic, and reproduce the exact diagnosed session/action invariant with fixed permits and worker
result evidence.
**Docs to update**: `documents/engineering/bootstrap_readiness_doctrine.md`,
`documents/engineering/vault_doctrine.md`, `DEVELOPMENT_PLAN/README.md`,
`DEVELOPMENT_PLAN/00-overview.md`, and `DEVELOPMENT_PLAN/system-components.md`.

**Live counterexample (2026-08-24)**: Broker Deployment generation 14 runs local image ID
`sha256:eb617339…` / registry digest `sha256:d8699b89…` with zero restarts. The corrected
generated-root one-shot worker reached terminal completion and its expired fence was retired with
absence receipt `377ecaf4…`; baseline then returned unchanged generic HTTP 409 `state-conflict`,
while the protected log named only `EnginePgpBoundaryRefused`. `prodbox vault status` still binds
the original `vault-reset-37bbd69a…` generation as initialized, unsealed, custody-durable,
root-session-active, and handoff-unobserved. No secret, Vault body, or free-form boundary detail is
needed to distinguish the existing closed PGP causes.

**First diagnostic result (2026-08-24)**: the diagnostic-only image deployed as local ID
`sha256:72336b36…` / registry digest `sha256:566df3ff…` in Deployment generation 15 with zero
restarts. Its protected log names `pgp-cause=generated-root-action-refused`. That constructor does
not yet identify the exact transition: production uses it for all four `GeneratedRootActionKind`
values and also for generated-token decoding before any action. The diagnostic therefore splits
pre-action token rejection into its own closed cause and attaches the existing closed action kind
to action refusal before another live observation. Public status/body remain unchanged.

**Refined diagnostic result (2026-08-24)**: local image ID `sha256:07aaa154…` / registry digest
`sha256:52ac3462…` deployed as Broker generation 16 with zero restarts and named
`generated-root-action-refused/apply-baseline`. Vault's read-only server log confirms the first
attempt created the `secret`, `transit`, and `pki` mounts plus Kubernetes auth; later generated-root
attempts complete without repeating those creation records. The apply action still contains two
sequential effects—`runVaultReconcile` and `reconcileVaultPkiBaseline`—so its refusal receives a
closed `core-reconcile`/`pki-reconcile` substage before behavior changes.

**Core-reconcile diagnostic result (2026-08-24)**: local image ID `sha256:598d91b7…` / registry
digest `sha256:2dcf66ea…` deployed as Broker generation 17 with zero restarts and named
`generated-root-action-refused/apply-baseline/core-reconcile`. The public result remains the exact
generic HTTP 409 `state-conflict`; status still binds the original `vault-reset-37bbd69a…`
generation as initialized, unsealed, custody-durable, root-session-active, and
handoff-unobserved. `core-reconcile` still collapses the closed `VaultReconcileError` algebra, so
the next diagnostic gives that sum exhaustive payload-free labels and observes its exact
constituent before any behavioral correction. Free-form context, HTTP bodies, paths, role names,
and secret-bootstrap detail remain outside both log and response.

**Closed core result (2026-08-24)**: the exhaustive reconciler projection deployed as generation
18, local image ID `sha256:1795b5e7…` / registry digest `sha256:3e1d5da8…`, with zero restarts and
named `core-reconcile/http/create-transit-key/status-500`. A disposable `--rm` Vault 1.18.3
instance reproduces the exact response: creating a `type=hmac` Transit key without `key_size`
returns HTTP 500 for an invalid zero-byte HMAC key, while explicitly supplying the documented
256-bit size as 32 bytes succeeds. The correction therefore belongs only in the HMAC
`TransitKeyRequest` encoding; AES and Ed25519 request bytes, desired types, key names, read-back,
and mismatch refusal remain unchanged.

**Corrected live result (2026-08-24)**: generation 19 runs local image ID
`sha256:475d37de…` / registry digest `sha256:2d320ec1…` with zero restarts. It retired the expired
generation-21 fence with an exact worker-absence receipt, crossed the former HMAC Transit-key
creation refusal, and now names only the subsequent
`generated-root-action-refused/apply-baseline/pki-reconcile` transition. The retained generation
remains initialized, unsealed, custody-durable, root-session-active, and handoff-unobserved.
Sprint `2.69` owns that distinct PKI refusal; it is not evidence against this sprint's exact wire
correction.

### Objective

Make the baseline route's closed PGP refusal actionable without exposing ciphertext, plaintext,
tokens, accessors, shares, key material, or free-form boundary detail. Diagnose the exact existing
boundary invariant from the retained run, correct only the evidenced Vault request encoding, and
resume the same durable root session.

### Deliverables

- Define one stable exhaustive secret-free label for every `PgpBoundaryError` constructor and
  render it only in the protected baseline-route diagnostic. Separate pre-action generated-token
  rejection from generated-root action refusal, and bind action refusal to the already closed
  `GeneratedRootActionKind`. Keep the public response byte-for-byte generic and keep other route
  diagnostics unchanged.
- Bind each root action refusal to a closed action-specific boundary stage; in particular,
  `apply-baseline` distinguishes the default core reconcile from the subsequent PKI reconcile.
- Deploy the diagnostic-only image first and capture the exact closed cause from the retained
  generation before authoring a behavioral correction.
- Encode Vault 1.18.3's required 32-byte size only for `type=hmac` Transit-key creation without
  changing the AES/Ed25519 wire, desired key inventory, read-back, or mismatch refusal.
- Add stable repository-owned positive HMAC and negative non-HMAC wire cases, plus a disposable
  same-version proof that omission reproduces the retained HTTP 500 and 32 bytes read back exact.
- Rebuild and deploy the Broker, resume normal reconcile, prove the exact HMAC refusal is crossed,
  and register any newly distinct subsequent transition before changing it. This sprint makes no
  claim that PKI, Lifecycle Authority readiness, or post-unseal handoff is complete; Sprint `2.69`
  owns that subsequent live path.

### Validation

1. Focused cases prove exhaustive closed-cause rendering, protected-only visibility, unchanged
   generic wire refusal, exact HMAC request encoding, and unchanged AES/Ed25519 encoding.
2. Warning-clean build, full unit suite, documentation lint, and `prodbox dev check` pass.
3. Diagnostic-only deployments progressively name the exact closed cause; the corrected deployment
   resumes the retained session without reinitializing Vault, crosses the HMAC creation failure,
   and either advances or registers the next distinct transition before any further behavior change.

### Remaining Work

None on this sprint's owned surface. Sprint `2.69` owns the separately observed PKI reconcile
refusal and the remaining baseline/Authority/handoff live path.

### Closure Record

- Exhaustive payload-free diagnostics cover the PGP token/action hierarchy, every generated-root
  substage, and all core reconciler HTTP/drift/secret-bootstrap causes; only the protected baseline
  route renders them and the public conflict remains generic.
- Focused diagnostic and Transit-key wire cases pass, including exact 32-byte HMAC encoding and
  unchanged AES/Ed25519 encodings. The warning-clean all-target build, documentation lint, **4631**
  primary unit cases, **27/33/29** authority suites, and heap-bounded canonical
  `prodbox dev check` all pass.
- Broker generation 19 runs local image ID `sha256:475d37de…` / registry digest
  `sha256:2d320ec1…` with zero restarts. It retired the expired generation-21 fence with absence
  receipt `a38afbb…`, crossed `core-reconcile/http/create-transit-key/status-500`, and exposed only
  Sprint `2.69`'s distinct `apply-baseline/pki-reconcile` refusal on the original retained
  generation.

## Sprint 2.69: PKI Reconcile Must Refuse With a Closed Cause [✅ Done]

**Status**: Done and correction live-proven — opened and closed 2026-08-24.
**Implementation**: `src/Prodbox/Vault/Reconcile.hs`,
`src/Prodbox/Bootstrap/Broker/PgpBoundary.hs`,
`src/Prodbox/Bootstrap/Broker/ProductionPgp.hs`, and focused validation under `test/unit/`.
**Deployment qualification**: pending — resume the retained root session through PKI baseline,
Lifecycle Authority readiness, and exact handoff read-back for the same storage generation.
**Independent Validation**: pure fixtures exhaust every PKI reconcile/observe operation and
payload-free HTTP/read-back cause, prove no Vault body or free-form `Text` enters the protected
diagnostic, and keep the public HTTP conflict unchanged.
**Docs to update**: `documents/engineering/bootstrap_readiness_doctrine.md`,
`documents/engineering/vault_doctrine.md`, `DEVELOPMENT_PLAN/README.md`,
`DEVELOPMENT_PLAN/00-overview.md`, and `DEVELOPMENT_PLAN/system-components.md`.

**Live counterexample (2026-08-24)**: corrected Broker generation 19 runs local image ID
`sha256:475d37de…` / registry digest `sha256:2d320ec1…` with zero restarts. The root action crosses
the complete default core reconciler, including explicit 32-byte HMAC key creation, then returns
the unchanged generic HTTP 409 while the protected log names only `apply-baseline/pki-reconcile`.
The PKI helpers still collapse issuer listing, root generation, role write, observe/read-back, and
drift into free-form `Either Text`.

**Closed diagnostic result (2026-08-24)**: Broker generation 20 runs local image ID
`sha256:e14ee898…` / registry digest `sha256:c320366b…` with zero restarts. Its protected log names
`generated-root-action-refused/apply-baseline/pki-reconcile/http/list-issuers/status-404`; the
public result remains the exact generic HTTP 409. Vault still reports the original
`vault-reset-37bbd69a…` generation initialized, unsealed, custody-durable, root-session-active, and
handoff-unobserved. A newly mounted PKI engine has no issuer collection, and the observation path
already represents an issuer-list 404 as baseline absence. The correction maps only that same 404
on the reconcile listing to generate-internal-root; a non-empty list remains keep-existing and all
other HTTP classes remain closed failures.

**Corrected live result (2026-08-24)**: Broker generation 21 runs local image ID
`sha256:37cb7d0f…` / registry digest `sha256:ef472adc…` with zero restarts. The exact 404-as-absent
decision generated the PKI root, reconciled the role, passed exact read-back, and advanced beyond
the entire generated-root PGP scope. The next protected refusal is the separately closed baseline
physical stage `prove-current-root-accessor-absent; boundary-refused`; the original retained
generation remains initialized, unsealed, custody-durable, root-session-active, and
handoff-unobserved. Sprint `2.70` owns that post-revocation proof and no further PKI behavior change
is licensed by this result.

### Objective

Replace the PKI baseline's free-form error channel with a closed payload-free algebra, diagnose the
exact retained transition, correct only that operation or read-back invariant, and resume the same
durable root session through post-unseal handoff.

### Deliverables

- Define closed PKI reconcile and observation error types whose constructors distinguish issuer
  listing, internal-root generation, role write, issuer/role read-back, and non-exact status without
  retaining response bodies, paths, names, tokens, or arbitrary text.
- Bind `GeneratedRootApplyPkiReconcile` and `GeneratedRootReadBackPkiObserve` to exhaustive stable
  secret-free cause labels visible only on the protected baseline diagnostic; keep every public
  response and unrelated route unchanged.
- Deploy the diagnostic first, observe the exact cause on the retained generation, and register
  any newly distinct transition before changing behavior.
- Correct only the evidenced PKI request or read-back rule, add its positive and negative fixture,
  then rebuild and resume until PKI closes or a distinct subsequent transition is registered. This
  sprint makes no claim that root-accessor cleanup, Authority readiness, or handoff is complete;
  Sprint `2.70` owns that subsequent live path.

### Validation

1. Focused tests exhaust the closed PKI cause mapping, protected-only rendering, generic public
   refusal, and the exact correction plus its negative arm.
2. Warning-clean all-target build, full unit suite, documentation lint, and `prodbox dev check`
   pass.
3. The diagnostic deployment names an exact PKI cause; the corrected deployment closes PKI
   reconcile/read-back on the original generation and either advances or registers the next
   distinct transition before further behavior changes.

### Remaining Work

None on this sprint's owned surface. Sprint `2.70` owns the subsequent accessor-absence proof and
remaining baseline/Authority/handoff path.

### Closure Record

- PKI reconcile and observe expose closed operation-indexed errors; the generated-root projection
  exhausts all mutation/read-back operations, four HTTP classes, nested observation failure, and
  exact absent/drifted/ready status without retaining payloads or free-form text.
- The pure root decision treats only successful empty issuer lists and HTTP 404 as fresh-mount
  absence; non-empty lists preserve the root and every other failure remains closed. Focused cases
  pass 2/2, the warning-clean all-target build, **4633** primary unit cases, **27/33/29** authority
  suites, documentation lint, and the heap-bounded canonical `prodbox dev check` all pass.
- Generation 20 diagnosed `pki-reconcile/http/list-issuers/status-404`. Corrected generation 21
  runs local image ID `sha256:37cb7d0f…` / registry digest `sha256:ef472adc…` with zero restarts,
  closes PKI reconcile/read-back, and exposes only Sprint `2.70`'s distinct
  `prove-current-root-accessor-absent` physical stage.

## Sprint 2.70: Current Root Revocation Needs an Exact Absence-Proof Cause [✅ Done]

**Status**: Done — reclosed 2026-08-24 after generation 25 crossed the corrected exact
current-accessor absence transition.
**Implementation**: `src/Prodbox/Bootstrap/Broker/Engine.hs`,
`src/Prodbox/Bootstrap/Broker/EngineAdapter.hs`,
`src/Prodbox/Bootstrap/Broker/ProductionEngine.hs`, and focused validation under `test/unit/`.
**Deployment qualification**: proven on the owned transition; Sprint `2.72` owns the next distinct
post-baseline inventory transition and the remaining aggregate baseline/Authority/handoff proof.
**Independent Validation**: pure physical-boundary fixtures exhaust the closed payload-free
absence-proof causes, prove only the protected baseline diagnostic renders them, and keep the public
HTTP refusal generic.
**Docs to update**: `documents/engineering/bootstrap_readiness_doctrine.md`,
`documents/engineering/vault_doctrine.md`, `DEVELOPMENT_PLAN/README.md`,
`DEVELOPMENT_PLAN/00-overview.md`, and `DEVELOPMENT_PLAN/system-components.md`.

**Live counterexample (2026-08-24)**: corrected Broker generation 21 runs local image ID
`sha256:37cb7d0f…` / registry digest `sha256:ef472adc…` with zero restarts. It closes PKI
reconcile/read-back and leaves the public baseline response generic, while the protected diagnostic
names `baseline-stage=prove-current-root-accessor-absent; boundary-refused`. The physical call still
collapses every `EngineBoundaryRefused Text` at this stage and therefore cannot identify the exact
retained absence invariant without free-form detail.

### Objective

Give the current generated-root accessor absence proof a closed payload-free refusal cause, observe
the exact retained invariant after revocation, correct only that proof, and resume the same durable
root session through Authority handoff.

### Deliverables

- Replace the absence proof's free-form boundary refusal at the protected diagnostic with a closed
  cause covering inventory identity/generation mismatch, stable-zero mismatch, HTTP class, and any
  other production constructor the exact proof boundary can return.
- Keep public responses generic and prevent accessor values, Vault bodies, tokens, paths, or
  arbitrary text from entering the diagnostic type.
- Deploy the diagnostic first, observe the retained cause, and register any distinct subsequent
  transition before changing it.
- Correct only the evidenced absence-proof invariant, add positive/negative fixtures, and resume
  baseline, Lifecycle Authority readiness, and exact handoff read-back.

### Validation

1. Focused cases exhaust the closed proof-cause mapping and protected-only rendering while public
   response bytes remain unchanged.
2. Warning-clean all-target build, full unit suite, documentation lint, and `prodbox dev check`
   pass.
3. The diagnostic names an exact absence-proof cause; the corrected deployment advances the same
   retained session through baseline and exact post-unseal handoff or registers the next distinct
   transition before further behavior changes.

### Remaining Work

None on this sprint's owned surface. Sprint `2.72` owns the separately registered post-baseline
inventory transition and the remaining aggregate baseline/Authority/handoff proof.

### Reopened Counterexample (2026-08-24)

- Diagnostic generation 24 runs local image ID `sha256:1acf4912…`, registry digest
  `sha256:668994ce…`, and containerd OCI manifest `sha256:46407e95…`, ready with zero restarts.
  Its protected diagnostic names
  `prove-current-root-accessor-absent; root-accessor-absence-cause=http/list-accessors/status-404`.
- The previous revocation has left the accessor collection empty; Vault answers LIST
  `auth/token/accessors` with 404 for that state. The current classifier preserves 404 as an HTTP
  failure instead of producing the empty inventory required by the exact absence decision.

### Reclosure Record (2026-08-24)

- Only accessor-list HTTP 404 is normalized to an empty inventory. Successful nonempty lists remain
  observations, while connection, timeout, non-404 status, and decode failures retain their exact
  closed refusal causes. The focused absence-list decision cases pass 3/3.
- Corrected generation 25 runs local image ID `sha256:ab22555f…`, registry digest
  `sha256:3e9cdbe8…`, and containerd OCI manifest `sha256:466816cf…`, ready with zero restarts. It
  crossed `prove-current-root-accessor-absent`, then crossed Sprint `2.71`'s post-baseline
  revocation transition, and exposed only Sprint `2.72`'s distinct
  `inventory-post-baseline-root-accessors` stage.
- The warning-clean all-target build, **4638** primary unit cases, **27/33/29** authority suites,
  documentation lint, and the heap-bounded canonical `prodbox dev check` all pass.

### Closure Record

- Root-accessor proof calls carry an explicit stable-zero versus exact-target requirement. Their
  production boundary maps projected-token, bounded-auditor login/cleanup, list/lookup HTTP,
  malformed observation, generation, target-present, and stable-zero failures into one closed
  payload-free cause; only the protected baseline diagnostic renders it.
- The integrated physical fixture introduces an unrelated root accessor after generated-root
  revocation. Exact current-target absence advances, while the subsequent explicit stable-zero
  program still inventories, revokes, and proves that unrelated accessor absent. Focused cases
  pass 2/2 plus three live-shaped baseline/recovery/target cases; the warning-clean all-target
  build, **4635** primary unit cases, **27/33/29** authority suites, documentation lint, and the
  heap-bounded canonical `prodbox dev check` all pass.
- Diagnostic generation 22 ran local image ID `sha256:337d6666…` / registry digest
  `sha256:8e0a72c4…` with zero restarts and named `stable-zero-mismatch`. Corrected generation 23
  runs local image ID `sha256:1f709707…` / registry digest `sha256:3a9b6878…` with zero restarts,
  crossed the exact target proof, and exposed only Sprint `2.71`'s subsequent
  `revoke-post-baseline-root-accessor` stage.

## Sprint 2.71: Post-Baseline Root Revocation Needs an Exact Cause [✅ Done]

**Status**: Done — closed 2026-08-24 after generation 25 crossed the exact post-baseline
root-accessor revocation transition.
**Implementation**: `src/Prodbox/Bootstrap/Broker/Engine.hs`,
`src/Prodbox/Bootstrap/Broker/EngineAdapter.hs`,
`src/Prodbox/Bootstrap/Broker/ProductionEngine.hs`, and focused validation under `test/unit/`.
**Deployment qualification**: proven on the owned transition; Sprint `2.72` owns the next distinct
post-baseline inventory transition and the remaining aggregate baseline/Authority/handoff proof.
**Independent Validation**: pure revocation-boundary fixtures exhaust a closed payload-free cause,
retain the generic public refusal, and prove exact post-call observation behavior.
**Docs to update**: `documents/engineering/bootstrap_readiness_doctrine.md`,
`documents/engineering/vault_doctrine.md`, `DEVELOPMENT_PLAN/README.md`,
`DEVELOPMENT_PLAN/00-overview.md`, and `DEVELOPMENT_PLAN/system-components.md`.

**Live counterexample (2026-08-24)**: corrected Broker generation 23 runs local image ID
`sha256:1f709707…` / registry digest `sha256:3a9b6878…` with zero restarts. It crosses the exact
current-root accessor absence proof and leaves the public response generic, while the protected
diagnostic names `baseline-stage=revoke-post-baseline-root-accessor; boundary-refused`. The
revocation call still collapses its exact Vault mutation and absence read-back outcomes into
free-form `EngineBoundaryError` detail.

### Objective

Give the post-baseline root-accessor revocation an exact payload-free cause, observe the retained
failure, correct only its evidenced invariant, and resume the same durable root session through
Authority handoff.

### Deliverables

- Replace the post-baseline revocation's free-form protected refusal with a closed cause covering
  auditor login, revoke HTTP outcome, list/read-back HTTP outcome, and exact absence status.
- Keep public responses generic and prevent accessor values, tokens, Vault bodies, paths, or
  arbitrary text from entering the diagnostic type.
- Deploy the diagnostic first, observe the retained cause, and register any distinct subsequent
  transition before changing it.
- Correct only the evidenced revocation/read-back invariant and resume baseline, Lifecycle
  Authority readiness, and exact handoff read-back.

### Validation

1. Focused cases exhaust the closed revocation mapping and protected-only rendering while public
   response bytes remain unchanged.
2. Warning-clean all-target build, full unit suite, documentation lint, and `prodbox dev check`
   pass.
3. The diagnostic names an exact post-baseline revocation cause; the corrected deployment advances
   the same retained session through baseline and exact post-unseal handoff or registers the next
   distinct transition before further behavior changes.

### Remaining Work

None on this sprint's owned surface. Sprint `2.72` owns the separately observed post-baseline root
inventory transition and the remaining aggregate baseline/Authority/handoff proof.

### Closure Record

- The revocation boundary carries a closed payload-free cause for projected-token availability,
  auditor login and cleanup, revoke/list HTTP operation and failure class, invalid login, and an
  exact target that remains present. Only the protected baseline diagnostic renders it; public
  refusal bytes remain generic. Exhaustive focused cause/rendering cases pass 2/2.
- Generation 25 runs local image ID `sha256:ab22555f…`, registry digest `sha256:3e9cdbe8…`, and
  containerd OCI manifest `sha256:466816cf…`, ready with zero restarts. It crossed
  `revoke-post-baseline-root-accessor` without a revocation failure and exposed only Sprint
  `2.72`'s distinct `inventory-post-baseline-root-accessors; boundary-unavailable` stage.
- The warning-clean all-target build, **4638** primary unit cases, **27/33/29** authority suites,
  documentation lint, and the heap-bounded canonical `prodbox dev check` all pass.

## Sprint 2.72: Post-Baseline Root Inventory Needs an Exact Cause [✅ Done]

**Status**: Done — closed 2026-08-24 after generation 27 crossed the corrected exact post-baseline
root-inventory transition.
**Implementation**: `src/Prodbox/Bootstrap/Broker/Engine.hs`,
`src/Prodbox/Bootstrap/Broker/EngineAdapter.hs`,
`src/Prodbox/Bootstrap/Broker/ProductionEngine.hs`, and focused validation under `test/unit/`.
**Deployment qualification**: proven on the owned transition; Sprint `2.73` owns the next distinct
provisioner-accessor cleanup transition and the remaining aggregate baseline/Authority/handoff
proof.
**Independent Validation**: pure inventory-boundary fixtures must exhaust the closed payload-free
cause, retain generic public refusal bytes, and distinguish an empty list from every refusal.
**Docs to update**: `documents/engineering/bootstrap_readiness_doctrine.md`,
`documents/engineering/vault_doctrine.md`, `DEVELOPMENT_PLAN/README.md`,
`DEVELOPMENT_PLAN/00-overview.md`, and `DEVELOPMENT_PLAN/system-components.md`.

**Live counterexample (2026-08-24)**: corrected Broker generation 25 runs local image ID
`sha256:ab22555f…`, registry digest `sha256:3e9cdbe8…`, and containerd OCI manifest
`sha256:466816cf…`, ready with zero restarts. It crosses exact current-root absence and
post-baseline revocation, then the protected diagnostic names
`baseline-stage=inventory-post-baseline-root-accessors; boundary-unavailable`. The production
inventory boundary still collapses projected-token, auditor-login, list, per-accessor policy
lookup, malformed-observation, and inventory-construction outcomes into broad text-bearing engine
failures, so the exact retained cause is not yet observable.

### Exact Diagnostic Observation (2026-08-24)

- Diagnostic generation 26 runs local image ID `sha256:936aab88…`, registry digest
  `sha256:82b9fe9e…`, and containerd OCI manifest `sha256:6dfdab10…`, ready 1/1 with zero restarts.
  Its protected diagnostic names
  `inventory-post-baseline-root-accessors; root-accessor-inventory-cause=http/list-accessors/status-404`.
- The prior revocation left the root-policy accessor collection empty. Vault answers LIST
  `auth/token/accessors` with 404 for that state, so post-baseline inventory must map only that
  exact result to an empty inventory while preserving every other failure class.

### Objective

Give post-baseline root inventory a closed payload-free cause, observe the exact retained failure,
correct only its evidenced invariant, and resume the same durable root session through Authority
handoff.

### Deliverables

- Replace post-baseline inventory's broad protected failure with a closed cause covering
  projected-token availability, auditor login/cleanup, list and policy-lookup HTTP outcomes,
  malformed observations, and inventory construction invariants.
- Keep public responses generic and prevent accessor values, policies, tokens, Vault bodies,
  paths, or arbitrary text from entering the diagnostic type.
- Deploy the diagnostic without changing inventory behavior, observe the exact live cause, and
  register any distinct subsequent transition before changing it.
- Correct only the evidenced inventory invariant and resume baseline, Lifecycle Authority
  readiness, and exact handoff read-back.

### Validation

1. Focused cases exhaust the closed inventory mapping and protected-only rendering while public
   response bytes remain unchanged.
2. Warning-clean all-target build, full unit suite, documentation lint, and `prodbox dev check`
   pass before live qualification.
3. The diagnostic names an exact post-baseline inventory cause; the corrected deployment advances
   through baseline and exact post-unseal handoff or registers the next distinct transition before
   further behavior changes.

### Remaining Work

None on this sprint's owned surface. Sprint `2.73` owns the separately observed
provisioner-accessor cleanup transition and the remaining aggregate baseline/Authority/handoff
proof.

### Closure Record

- Root inventory now has 20 exhaustive payload-free causes across projected-token/auditor cleanup,
  three HTTP operations and four failure classes, malformed accessor, and inventory construction.
  Only the protected baseline route renders the exact cause; public replies retain their generic
  unavailable/refused/ambiguous classes.
- Only inventory-list HTTP 404 supplies the empty inventory Vault represents. Successful nonempty
  lists remain observations; connection, timeout, every non-404 status, and decode failure retain
  their exact cause. Focused exhaustive/classifier/decision cases pass 3/3.
- Diagnostic generation 26 (local image ID `sha256:936aab88…`, registry digest
  `sha256:82b9fe9e…`, OCI manifest `sha256:6dfdab10…`) named
  `http/list-accessors/status-404`. Corrected generation 27 runs local image ID
  `sha256:d3a26728…`, registry digest `sha256:d3034ee4…`, and OCI manifest
  `sha256:d871d358…`, ready 1/1 with zero restarts. It crossed post-baseline root inventory and
  exposed only Sprint `2.73`'s distinct `cleanup-provisioner-accessors; boundary-unavailable`
  transition.
- The warning-clean all-target build, **4641** primary unit cases, **27/33/29** authority suites,
  documentation lint, and the heap-bounded canonical `prodbox dev check` all pass.

## Sprint 2.73: Provisioner-Accessor Cleanup Needs an Exact Cause [✅ Done]

**Status**: Done — closed 2026-08-24 after generation 29 crossed the corrected exact cleanup
transition.
**Implementation**: `src/Prodbox/Bootstrap/Broker/Engine.hs`,
`src/Prodbox/Bootstrap/Broker/EngineAdapter.hs`,
`src/Prodbox/Bootstrap/Broker/ProductionEngine.hs`, and focused validation under `test/unit/`.
**Deployment qualification**: proven on the owned transition; Sprint `2.74` owns the next distinct
provisioner-policy application transition and the remaining aggregate baseline/Authority/handoff
proof.
**Independent Validation**: pure cleanup-boundary fixtures must exhaust the closed payload-free
cause, retain generic public reply bytes, and cover every list/lookup/revoke/absence decision arm.
**Docs to update**: `documents/engineering/bootstrap_readiness_doctrine.md`,
`documents/engineering/vault_doctrine.md`, `DEVELOPMENT_PLAN/README.md`,
`DEVELOPMENT_PLAN/00-overview.md`, and `DEVELOPMENT_PLAN/system-components.md`.

**Live counterexample (2026-08-24)**: corrected Broker generation 27 runs local image ID
`sha256:d3a26728…`, registry digest `sha256:d3034ee4…`, and containerd OCI manifest
`sha256:d871d358…`, ready 1/1 with zero restarts. It crosses post-baseline root inventory, then the
protected diagnostic names `baseline-stage=cleanup-provisioner-accessors; boundary-unavailable`.
The cleanup boundary still collapses projected-token/login, role-wide list and subject lookup,
revoke, visibility, exact absence, and stable-zero audit outcomes into broad text-bearing engine
failures, so the retained cause is not yet observable.

**Current validation state (2026-08-24)**: the diagnostic-only implementation uses a shared typed
detailed stable-zero audit, preserves provisional revoke semantics, and exposes 41 unique
payload-free cleanup causes only at the protected baseline route. Focused cases pass 3/3; the
warning-clean all-target build, **4644** primary unit cases, documentation lint, and the
heap-bounded canonical `prodbox dev check` pass. Ready, zero-restart diagnostic generation 28 runs
local image ID `sha256:65a7127d…`, registry digest `sha256:8d3f4a7e…`, and OCI manifest
`sha256:9b7a8d0c…`; it names the exact cause
`http/initial-list-accessors/status-404`. Only cleanup's shared LIST empty-collection decision now
required correction. The shared classifier now admits only exact HTTP 404 as empty at both initial
and repeated list sites; focused cases pass 3/3, all **4644** primary unit cases pass, and the
warning-clean all-target build, documentation lint, and heap-bounded canonical `prodbox dev check`
pass. Corrected generation 29 runs local image ID
`sha256:5f456f04039f8c2d2d5d67b76194ced6fa68c618efffdb42e0c125f41d1cf8ea`, registry digest
`sha256:c854aa67b448b4c903955e126bccdf7c6490d62b15a4f1670870cb7ae1192a0f`, and containerd OCI
manifest `sha256:d469027cf1c1e263cf89d79c5d1088a626eb11d562d384470e1ea3a390d0c69e` in Deployment
generation 29, ready 1/1 with zero restarts. It crossed cleanup and exposed only Sprint `2.74`'s
distinct `apply-provisioner-policy; boundary-unavailable` transition; the public response remained
the generic HTTP 503 boundary-unavailable body.

### Objective

Give provisioner-accessor cleanup a closed payload-free cause, observe the exact retained failure,
correct only its evidenced invariant, and resume the same durable session through baseline and
Authority handoff.

### Deliverables

- Replace cleanup's broad protected failure with a closed cause covering projected-token and
  bounded-auditor login/cleanup, initial and repeated list/lookup HTTP outcomes, typed provisional
  revoke/direct-absence operations, visibility, subject classification, and stable-zero
  invariants. Cleanup carries no known accessor, so direct-known-absence is an exhaustive operation
  arm but not a terminal step on this role-wide lane; revoke responses likewise remain provisional
  and later authoritative observations decide closure.
- Keep public responses generic and prevent accessors, subjects, roles, tokens, Vault bodies,
  paths, or arbitrary text from entering the diagnostic type.
- Deploy the diagnostic without changing cleanup behavior, observe the exact live cause, and
  register any distinct subsequent transition before changing it.
- Correct only the evidenced cleanup invariant and resume baseline, Lifecycle Authority readiness,
  and exact handoff read-back.

### Validation

1. Focused cases exhaust the closed cleanup mapping and protected-only rendering while public reply
   bytes remain unchanged.
2. Warning-clean all-target build, full unit suite, documentation lint, and `prodbox dev check`
   pass before live qualification.
3. The diagnostic names an exact provisioner-cleanup cause; the corrected deployment advances
   through baseline and exact post-unseal handoff or registers the next distinct transition before
   further behavior changes.

### Remaining Work

None on this sprint's owned surface. Sprint `2.74` owns the separately observed
provisioner-policy application transition and the remaining aggregate baseline/Authority/handoff
proof.

### Closure Record

- Cleanup carries 41 unique payload-free causes across projected-token, bounded-auditor,
  initial/repeated list and lookup, provisional revoke, visibility, subject, and stable-zero
  outcomes. Only the protected route renders them; public replies remain generic.
- Diagnostic generation 28 named exact `http/initial-list-accessors/status-404`. The shared
  classifier admits only exact LIST HTTP 404 as Vault's empty collection at both initial and
  repeated audit sites; every other HTTP class remains a typed refusal and revoke responses remain
  provisional. Focused exhaustive/classifier cases pass 3/3.
- Corrected generation 29 carries the exact identities and live transition recorded above, is
  ready 1/1 with zero restarts, and crossed cleanup before exposing Sprint `2.74`'s separately
  registered policy-application boundary.
- The warning-clean all-target build, **4644** primary unit cases, documentation lint, and the
  heap-bounded canonical `prodbox dev check` all pass.

## Sprint 2.74: Provisioner-Policy Application Needs an Exact Cause [✅ Done]

**Status**: Done — closed 2026-08-24 after generation 30 crossed policy application and read-back
without a behavior correction.
**Implementation**: `src/Prodbox/Bootstrap/Broker/Engine.hs`,
`src/Prodbox/Bootstrap/Broker/EngineAdapter.hs`,
`src/Prodbox/Bootstrap/Broker/ProductionEngine.hs`, and focused validation under `test/unit/`.
**Deployment qualification**: proven on the owned transition; Sprint `2.75` owns the next distinct
provisioner-accessor revocation transition and the remaining baseline, Lifecycle Authority, and
handoff read-back.
**Independent Validation**: pure policy-application fixtures must exhaust the closed payload-free
cause, retain generic public reply bytes, and distinguish provisioner-token lookup, Vault baseline
reconcile, and PKI reconcile outcomes.
**Docs to update**: `documents/engineering/bootstrap_readiness_doctrine.md`,
`documents/engineering/vault_doctrine.md`, `DEVELOPMENT_PLAN/README.md`,
`DEVELOPMENT_PLAN/00-overview.md`, and `DEVELOPMENT_PLAN/system-components.md`.

**Live counterexample (2026-08-24)**: corrected Broker generation 29 runs the exact identities
recorded in Sprint `2.73`, ready 1/1 with zero restarts. It crosses provisioner-accessor cleanup,
then the protected diagnostic names
`baseline-stage=apply-provisioner-policy; boundary-unavailable`. The public response remains the
generic HTTP 503 boundary-unavailable body. `applyProvisionerBaseline` still collapses
provisioner-token registry lookup, the default Vault reconcile program, and PKI reconcile outcomes
into broad `EngineBoundaryError` classes, so the exact retained cause is not yet observable.

**Current validation state (2026-08-24)**: the diagnostic-only implementation introduces one
stage-specific closed cause over missing process-local token state and the existing shared
payload-free core/PKI reconcile projections. The shared classifiers remain exhaustive over every
Vault HTTP operation/class, typed drift, nested secret-bootstrap CAS outcome, PKI observation
failure, and non-exact status. All 78 rendered causes are unique, appear only on the protected
baseline route, retain no arbitrary payload, and preserve the prior generic HTTP 503 public reply.
Focused cases pass 2/2, the warning-clean all-target build and all **4646** primary unit cases pass,
documentation lint is clean, and the heap-bounded canonical `prodbox dev check` passes.
Diagnostic-only generation 30 crossed policy application and its read-back without reproducing the
earlier broad failure, so policy-application behavior remains unchanged.

### Objective

Give provisioner-policy application a closed payload-free cause, observe the exact retained
failure, correct only its evidenced invariant, and resume the same durable session through
baseline and Authority handoff.

### Deliverables

- Replace policy application's broad protected failure with a closed cause covering provisioner
  token lookup, default Vault reconcile, and PKI reconcile operation/outcome classes.
- Keep public responses generic and prevent tokens, Vault bodies, paths, policy material, or
  arbitrary text from entering the diagnostic type.
- Deploy the diagnostic without changing policy-application behavior, observe the exact live
  cause, and register any distinct subsequent transition before changing it.
- Correct only the evidenced invariant and resume baseline, Lifecycle Authority readiness, and
  exact handoff read-back.

### Validation

1. Focused cases exhaust the closed policy-application mapping and protected-only rendering while
   public response bytes remain unchanged.
2. Warning-clean all-target build, full unit suite, documentation lint, and `prodbox dev check`
   pass before live qualification.
3. The diagnostic names an exact policy-application cause; the corrected deployment advances
   through baseline and exact post-unseal handoff or registers the next distinct transition before
   further behavior changes.

### Remaining Work

None on this sprint's owned surface. Sprint `2.75` owns the separately observed
provisioner-accessor revocation transition and the remaining aggregate baseline/Authority/handoff
proof.

### Closure Record

- The diagnostic boundary carries 78 unique payload-free causes across process-local token lookup,
  the exhaustive core Vault reconcile projection, and the exhaustive PKI reconcile/read-back
  projection. Only the protected route renders them; public responses retain the generic HTTP 503
  body. Focused cases pass 2/2.
- Diagnostic-only generation 30 runs local image ID
  `sha256:8ca4523193be3e2cd3a60148dfd2c919231dd45c4b1108e3c475f475be539a4c`, registry digest
  `sha256:8d7480383b5a2d9445beb30b2b74d1e44dc7a946c949d235135fa2b70ae1a0c0`, and containerd OCI
  manifest `sha256:e1df135dfb3f59991677f8d94ebc6967f7747c46acc8a2a92ffc213fc397ab0b`, ready 1/1 with zero
  restarts. It did not reproduce generation 29's broad refusal: policy application and read-back
  crossed unchanged, so no correction was justified. The durable program then exposed Sprint
  `2.75`'s distinct `revoke-provisioner-accessor; boundary-unavailable` transition.
- The warning-clean all-target build, **4646** primary unit cases, documentation lint, and the
  heap-bounded canonical `prodbox dev check` all pass.

## Sprint 2.75: Provisioner-Accessor Revocation Needs an Exact Cause [✅ Done]

**Status**: Done and live-proven — generation 38 crossed the exact initial accessor-LIST HTTP 404
and exposed Sprint `2.81`'s distinct post-revocation LIST 404.
**Implementation**: `src/Prodbox/Bootstrap/Broker/Engine.hs`,
`src/Prodbox/Bootstrap/Broker/EngineAdapter.hs`,
`src/Prodbox/Bootstrap/Broker/ProductionEngine.hs`, and focused validation under `test/unit/`.
**Deployment qualification**: proven — generation 38 crossed the owned correction under the exact
ready, zero-restart runtime identity recorded below.
**Independent Validation**: pure provisioner-revocation fixtures must exhaust the closed
payload-free cause, retain generic public reply bytes, and distinguish bounded-auditor,
inventory, lookup, revocation, and post-revocation outcomes.
**Docs to update**: `documents/engineering/bootstrap_readiness_doctrine.md`,
`documents/engineering/vault_doctrine.md`, `DEVELOPMENT_PLAN/README.md`,
`DEVELOPMENT_PLAN/00-overview.md`, and `DEVELOPMENT_PLAN/system-components.md`.

**Live counterexample (2026-08-24)**: diagnostic-only Broker generation 30 runs the exact
identities recorded in Sprint `2.74`, ready 1/1 with zero restarts. It crosses policy application
and read-back, then the protected diagnostic names
`baseline-stage=revoke-provisioner-accessor; boundary-unavailable`. The public response remains
the generic HTTP 503 boundary-unavailable body. `revokeProvisionerSession` still collapses bounded
auditor login/cleanup, initial inventory, accessor lookup/subject verification, exact revocation,
and authoritative post-revocation inventory into broad `EngineBoundaryError` classes, so the
retained cause is not yet observable.

**Current handoff (2026-08-26)**: the closed cause now exists in the worktree and the production
revocation path projects bounded-auditor, initial inventory, target lookup/identity, revoke, and
post-revocation inventory/absence outcomes without changing the public reply classification.
Focused cases pass 2/2, all **4648** primary unit cases plus the **27/33/29** authority suites pass,
documentation lint and the warning-clean all-target build pass, and the canonical `prodbox dev
check` exits 0. No diagnostic deployment, exact live cause observation, or behavior correction has
occurred. The supported retry observed and deleted the completed registry storage bootstrap Job,
brought the registry to Ready, published/imported the diagnostic image, and applied Broker
generation 31. Sprint `3.45`'s corrected generation 32 then crossed the revision observer and
reached baseline, where the protected diagnostic named the separate earlier-stage
`revoke-post-baseline-root-accessor; root-accessor-revocation-cause=http/list-read-back/status-404`.
Sprint `2.76` closed that invariant; generation 33 then exposed Sprint `2.77`'s distinct
provisioner policy-write 403. Generation 37 crossed Sprints `2.77` through `2.80` and the protected
diagnostic now names
`provisioner-accessor-revocation-cause=http/initial-list-accessors/status-404`; the public response
remains generic HTTP 503. Resume at Remaining Work item 3.

### Objective

Give provisioner-accessor revocation a closed payload-free cause, observe the exact retained
failure, correct only its evidenced invariant, and resume the same durable session through
baseline and Authority handoff.

### Deliverables

- Replace provisioner revocation's broad protected failure with a closed cause covering bounded
  auditor login and cleanup, initial accessor inventory, target lookup and subject verification,
  revoke HTTP outcome, post-revocation inventory, and exact target/role absence status.
- Keep public responses generic and prevent accessors, subjects, roles, tokens, Vault bodies,
  paths, or arbitrary text from entering the diagnostic type.
- Deploy the diagnostic without changing revocation behavior, observe the exact live cause, and
  register any distinct subsequent transition before changing it.
- Correct only the evidenced invariant and resume baseline, Lifecycle Authority readiness, and
  exact handoff read-back.

### Validation

1. Focused cases exhaust the closed provisioner-revocation mapping and protected-only rendering
   while public response bytes remain unchanged.
2. Warning-clean all-target build, full unit suite, documentation lint, and `prodbox dev check`
   pass before live qualification.
3. The diagnostic names an exact provisioner-revocation cause; the corrected deployment advances
   through baseline and exact post-unseal handoff or registers the next distinct transition before
   further behavior changes.

### Remaining Work

1. ~~Complete the diagnostic build and exhaustive focused validation.~~ Done 2026-08-26: 2/2
   focused cases pass and preserve the existing public classifications.
2. ~~Complete the remaining local validation and deploy the diagnostic.~~ Done 2026-08-26: the
   warning-clean all-target build, **4648** primary unit cases plus **27/33/29** authority suites,
   documentation lint, and canonical `prodbox dev check` pass. Generation 37 crossed every earlier
   transition and named exact `http/initial-list-accessors/status-404` while preserving the generic
   public HTTP 503 response.
3. ~~Correct only the evidenced invariant and resume baseline, Authority readiness, and exact
   handoff; close only after the owned transition crosses and any next distinct transition is
   registered.~~ Done 2026-08-26: the classifier admits HTTP 404 only for the initial accessor
   LIST, keeps the post-revocation LIST and every other failure closed, and passes its focused case
   1/1. All **4653** primary cases, the **27/33/29** authority suites, documentation lint,
   warning-clean all-target build, and canonical `prodbox dev check` pass. Generation 38 runs
   local image `sha256:39be376e…`, registry digest `sha256:6bf24c4a…`, and containerd OCI manifest
   `sha256:aedc95fd…`, observed and ready 1/1 with zero restarts. It crossed the initial LIST and
   exposed Sprint `2.81`'s separately registered exact `http/post-list-accessors/status-404`.

## Sprint 2.76: Empty Post-Revocation Root Inventory Is LIST 404 [✅ Done]

**Status**: Done and live-proven — opened and closed 2026-08-26.
**Implementation**: `src/Prodbox/Bootstrap/Broker/ProductionEngine.hs` and focused validation under
`test/unit/BootstrapBrokerEnginePhysical.hs`.
**Deployment qualification**: proven — generation 33 crossed the exact post-revocation observation
and reached the subsequent provisioner policy application transition.
**Independent Validation**: pure classification proves only post-revocation LIST 404 becomes an
empty collection; successful lists and every other typed HTTP failure retain their existing meaning.
**Docs to update**: `documents/engineering/bootstrap_readiness_doctrine.md`,
`documents/engineering/vault_doctrine.md`, `DEVELOPMENT_PLAN/README.md`,
`DEVELOPMENT_PLAN/00-overview.md`, and `DEVELOPMENT_PLAN/system-components.md`.

### Objective

Treat Vault's exact empty token-accessor collection result after revoking the last root accessor as
successful absence without broadening revocation or masking any other observation failure.

### Live Counterexample (2026-08-26)

Broker generation 32 crossed the corrected Sprint `3.45` observer and reached baseline on retained
Vault storage generation `vault-a290544e…`. After the post-baseline root accessor was revoked, Vault
answered the authoritative accessor LIST with HTTP 404. The protected diagnostic rendered
`baseline-stage=revoke-post-baseline-root-accessor; root-accessor-revocation-cause=http/list-read-back/status-404`;
the public reply remained generic HTTP 503. The same empty-collection representation is already
admitted by the separate root absence and inventory classifiers, but this revocation read-back still
classifies every LIST failure as an error.

### Deliverables

- Add a closed post-revocation list classifier that maps only HTTP 404 to the empty accessor set.
- Preserve successful listing contents, every other HTTP failure, the target-still-present refusal,
  and all public response bytes.
- Deploy the correction, cross this exact transition, and register any later distinct transition
  before changing it.

### Validation

1. Focused cases cover successful lists, HTTP 404, connection failure, timeout, non-404 status, and
   decode failure without retaining response payloads.
2. Warning-clean all-target build, full unit and authority suites, documentation lint, and
   `prodbox dev check` pass before live qualification.
3. The corrected deployment crosses post-baseline root revocation and reaches Sprint `2.75`'s
   provisioner-accessor diagnostic or registers the next distinct transition.

### Remaining Work

1. ~~Implement the narrow classifier and focused proof.~~ Done 2026-08-26: only immediate
   post-revocation LIST HTTP 404 becomes `Right []`; the successful and four remaining failure
   classes retain their exact outcomes.
2. ~~Run the complete local gate.~~ Done 2026-08-26: focused case, all **4650** primary unit cases
   plus **27/33/29** authority suites, documentation lint, warning-clean all-target build, and
   canonical `prodbox dev check` pass.
3. ~~Deploy and record the exact crossing.~~ Done 2026-08-26: generation 33 runs local image
   `sha256:73bb4e26…`, registry digest `sha256:035cbac6…`, and containerd manifest
   `sha256:38971371…`, ready 1/1 with zero restarts; Sprint `2.77` owns the distinct policy-write
   403 observed next.

## Sprint 2.77: Provisioner Policy Repair Needs Its Own Authority [✅ Done]

**Status**: Done — narrow authority split passed the complete local gate and crossed live on
generation 36 on 2026-08-26.
**Implementation**: `src/Prodbox/Bootstrap/Broker/ProductionEngine.hs`, the relevant Vault policy
projection, and focused validation under `test/unit/`.
**Deployment qualification**: proven — generation 36 crossed exact repair-policy write/read-back;
Sprint `2.80` owns the distinct later ordinary Kubernetes-role authorization refusal.
**Independent Validation**: pure policy and transition fixtures prove the writer owns exactly the
needed policy coordinate without gaining unrelated root authority; all public response bytes remain
unchanged.
**Docs to update**: `documents/engineering/bootstrap_readiness_doctrine.md`,
`documents/engineering/vault_doctrine.md`, `DEVELOPMENT_PLAN/README.md`,
`DEVELOPMENT_PLAN/00-overview.md`, and `DEVELOPMENT_PLAN/system-components.md`.

### Objective

Give fresh-generation provisioner-policy repair an authority that can write and read back exactly
that policy at the point the durable baseline program performs it, without granting the
provisioner generic root authority or masking a Vault refusal.

### Live Counterexample (2026-08-26)

Broker generation 33 crossed post-baseline root revocation, provisioner cleanup, and provisioner
login on retained Vault generation `vault-a290544e…`. Its protected diagnostic then rendered
`baseline-stage=apply-provisioner-policy; provisioner-policy-application-cause=core-reconcile/http/write-policy/status-403`;
the public reply remained generic HTTP 503. An older retained generation had already carried a
sufficient policy and did not reproduce this fresh-generation authorization path, so only the
current exact 403 licenses a change.

### Deliverables

- Trace the token/policy used for the exact provisioner policy write and identify why a fresh
  generation lacks the required capability.
- Correct only that authority or transition order, retain least privilege, and preserve exact
  policy read-back plus every non-403 failure.
- Add a structural/pure regression that fails if the writer loses the exact policy capability or
  gains unrelated root authority.
- Deploy the correction, cross this exact transition, and register any later distinct transition
  before changing it.

### Validation

1. Focused cases prove the exact policy coordinate and least-privilege capability, plus unchanged
   closed error and public-reply classification.
2. Warning-clean all-target build, full unit and authority suites, documentation lint, and
   `prodbox dev check` pass before live qualification.
3. The corrected deployment crosses provisioner policy write/read-back and reaches Sprint `2.75`'s
   provisioner-accessor diagnostic or registers the next distinct transition.

### Remaining Work

1. ~~Trace the exact fresh-generation policy authority and implement the narrow correction.~~ Done
   2026-08-26: Vault's ACL-policy endpoint requires root-protected `sudo`; a separate accessor-free
   batch role now owns only `sys/policies/acl/prodbox-bootstrap-provisioner`, immediately reads the
   exact document back, cannot edit itself or a wildcard, and the ordinary provisioner plan writes
   no ACL policies. The two coordinates append to the baseline target algebra without retagging
   old constructors; a completed retained journal with the prior target set restarts through
   orphan cleanup and a new short-lived root session, which seeds the role without bypassing the
   Broker. Focused closed-cause and structural cases pass.
2. ~~Run the complete local gate.~~ Done 2026-08-26: **4650** primary cases, the **27/33/29**
   authority suites, documentation lint, warning-clean all-target build, and canonical
   `prodbox dev check` pass.
3. ~~Deploy, record the exact crossing, and resume Sprint `2.75`.~~ Done 2026-08-26: generation 36
   runs local image `sha256:5e339bef…`, registry digest `sha256:338b1738…`, and containerd OCI
   manifest `sha256:32776229…`, ready 1/1 with zero restarts. The dedicated repair role crossed
   exact ACL-policy write/read-back; Sprint `2.80` owns the next ordinary Kubernetes-role 403.

## Sprint 2.78: Older Closed Baseline Receipt Must Reach Its Restart Program [✅ Done]

**Status**: Done — terminal-only retained admission passed the complete local gate and crossed live
on generation 35 on 2026-08-26.
**Implementation**: `src/Prodbox/Bootstrap/Broker/Model.hs`,
`src/Prodbox/Bootstrap/Broker/ProductionStore.hs`, and focused validation under `test/unit/`.
**Deployment qualification**: proven — generation 35 crossed the former status-read refusal and
entered the old-target baseline restart, exposing Sprint `2.79`'s distinct replacement-ID conflict.
**Independent Validation**: a legacy-wire fixture must decode and pass store validity only as an
exact older closed receipt; current construction and every in-progress baseline phase remain
current-target-only.
**Docs to update**: `documents/engineering/bootstrap_readiness_doctrine.md`,
`documents/engineering/vault_doctrine.md`, `DEVELOPMENT_PLAN/README.md`,
`DEVELOPMENT_PLAN/00-overview.md`, and `DEVELOPMENT_PLAN/system-components.md`.

### Objective

Permit the exact pre-repair completed baseline receipt through the retained store read boundary so
the engine can select its already-defined orphan-cleanup/generated-root restart, without admitting
partial or arbitrary obsolete baseline evidence.

### Live Counterexample (2026-08-26)

Broker generation 34 runs the Sprint `2.77` image ready 1/1 with zero restarts, but both supported
reconcile and `prodbox vault status` receive the public generic HTTP 503
`boundary-unavailable` before baseline execution. The older target-list CBOR decodes exactly in a
focused regression. `ProductionStore.validRootSession` then rejects the closed receipt because
`baselineViolations` requires the expanded current target set, so
`loadOrCreateRootSessionJournal` cannot observe it and execute its explicit old-target restart
branch.

### Deliverables

- Define the one exact prior baseline target set accepted for retained closed-receipt reads.
- Keep receipt construction, transition validation, and every non-terminal baseline phase strict
  to the current target set.
- Prove the accepted older closed receipt restarts through the normal generated-root program and
  arbitrary/incomplete target sets remain corrupt.
- Deploy the correction and resume Sprint `2.77`'s live policy crossing.

### Validation

1. Focused wire/store/model cases prove exact old-closed admission, arbitrary-old rejection, and
   current-only construction/in-progress transitions.
2. Warning-clean all-target build, full unit and authority suites, documentation lint, and
   `prodbox dev check` pass before live qualification.
3. The corrected deployment observes the retained journal, runs the root-session restart, and
   reaches Sprint `2.77`'s policy repair or registers the next distinct transition.

### Remaining Work

1. ~~Implement the exact terminal-only retained-receipt admission and focused regressions.~~ Done
   2026-08-26: the store/model invariant admits only the exact pre-policy-repair target list in
   `RootSessionClosed`; construction and every in-progress phase stay current-only, a partial old
   list remains corrupt, and the decoded legacy receipt restarts through orphan cleanup with a new
   session identity. Focused cases pass 2/2.
2. ~~Run the complete local gate.~~ Done 2026-08-26: all **4652** primary cases, the **27/33/29**
   authority suites, documentation lint, warning-clean all-target build, and canonical
   `prodbox dev check` pass.
3. ~~Deploy, record the exact crossing, and resume Sprint `2.77`.~~ Done 2026-08-26: generation 35
   runs local image `sha256:387c193f…`, registry digest `sha256:9df1ab70…`, and containerd OCI
   manifest `sha256:72d6f78a…`, ready 1/1 with zero restarts. Vault unseal and baseline entry cross
   the former `boundary-unavailable`; Sprint `2.79` owns the next exact
   `RootSessionRestartMustAdvanceSessionId` conflict.

## Sprint 2.79: Older Completion Restart Needs an Advanced Session Identity [✅ Done]

**Status**: Done — the closed identity plan passed the complete local gate and crossed live on
generation 36 on 2026-08-26.
**Implementation**: `src/Prodbox/Bootstrap/Broker/ProductionEngine.hs` and focused validation under
`test/unit/BootstrapBrokerEnginePhysical.hs`.
**Deployment qualification**: proven — generation 36 entered orphan cleanup and generated-root
baseline under an advanced session identity.
**Independent Validation**: production evidence fixtures prove a fresh ID only for a completed
noncurrent baseline; current completion and cancelled-clean journals reuse their retained IDs, and
unfinished sessions retain the existing fresh-ID behavior.
**Docs to update**: `documents/engineering/bootstrap_readiness_doctrine.md`,
`documents/engineering/vault_doctrine.md`, `DEVELOPMENT_PLAN/README.md`,
`DEVELOPMENT_PLAN/00-overview.md`, and `DEVELOPMENT_PLAN/system-components.md`.

### Objective

Give the exact older completed receipt the replacement session identity its native restart model
requires, without changing identity reuse for current terminal evidence or weakening any custody
transition.

### Live Counterexample (2026-08-26)

Generation 35 crosses retained-store decoding and validation, unseals Vault, and enters baseline.
The protected log names `EngineCustodyTransitionRefused` and the supported command returns HTTP 409
`state-conflict`. `baselineEvidence` returns the retained session ID whenever
`rootSessionIsComplete` is true, including the exact older target set. `restartRootSession` then
correctly refuses that same ID with `RootSessionRestartMustAdvanceSessionId`; no mutation occurs.

### Deliverables

- Expose the current-baseline predicate needed at the production evidence boundary.
- Mint a fresh session ID for the exact completed-but-noncurrent journal and preserve every other
  evidence-selection arm.
- Prove the selected ID advances and the old completion restarts through the normal program.
- Deploy the correction and resume Sprint `2.77`'s policy-repair crossing.

### Validation

1. Focused evidence/model cases cover noncurrent completion, current completion, cancelled-clean,
   unfinished, and fresh-absent journals.
2. Warning-clean all-target build, full unit and authority suites, documentation lint, and
   `prodbox dev check` pass before live qualification.
3. The corrected deployment enters orphan cleanup under a new ID and reaches Sprint `2.77` or
   registers the next distinct transition.

### Remaining Work

1. ~~Implement the exact evidence-selection correction and focused regressions.~~ Done 2026-08-26:
   a closed `BaselineSessionIdentityPlan` reuses only current-complete and cancelled-clean IDs;
   old completion, unfinished state, and absence mint fresh IDs. The real legacy receipt selects
   fresh and restarts with an advanced ID. Focused cases pass 2/2.
2. ~~Run the complete local gate.~~ Done 2026-08-26: all **4653** primary cases, the **27/33/29**
   authority suites, documentation lint, warning-clean all-target build, and canonical
   `prodbox dev check` pass.
3. ~~Deploy, record the exact crossing, and resume Sprint `2.77`.~~ Done 2026-08-26: generation 36
   runs local image `sha256:5e339bef…`, registry digest `sha256:338b1738…`, and containerd OCI
   manifest `sha256:32776229…`, ready 1/1 with zero restarts. It crossed the prior state conflict,
   ran orphan cleanup and generated-root baseline with the new ID, and live-proved Sprint `2.77`'s
   repair authority before Sprint `2.80`'s distinct ordinary Kubernetes-role refusal.

## Sprint 2.80: Ordinary Provisioner Lacks Kubernetes-Auth Role Write [✅ Done]

**Status**: Done and live-proven — generation 37 crossed the exact compiled Kubernetes-role
write/read-back and exposed Sprint `2.75`'s distinct accessor-list transition.
**Implementation**: the compiled provisioner policy in `src/Prodbox/Vault/Reconcile.hs`, production
reconcile projection, and focused validation under `test/unit/`.
**Deployment qualification**: proven — generation 37 crossed every canonical Kubernetes-auth role
write/read-back under the repaired ordinary policy.
**Independent Validation**: structural policy fixtures prove the ordinary provisioner owns exactly
the required Kubernetes role coordinate without ACL-policy, wildcard, or unrelated root authority;
closed HTTP classification and public reply bytes remain unchanged.
**Docs to update**: `documents/engineering/bootstrap_readiness_doctrine.md`,
`documents/engineering/vault_doctrine.md`, `DEVELOPMENT_PLAN/README.md`,
`DEVELOPMENT_PLAN/00-overview.md`, and `DEVELOPMENT_PLAN/system-components.md`.

### Objective

Grant the ordinary provisioner the exact Kubernetes-auth role coordinate required by its policy-free
core reconcile plan, while keeping ACL-policy repair isolated in the accessor-free repair role.

### Live Counterexample (2026-08-26)

Broker generation 36 crosses the old-target restart and dedicated provisioner ACL-policy
write/read-back, then the protected diagnostic renders
`baseline-stage=apply-provisioner-policy; provisioner-policy-application-cause=core-reconcile/http/write-kubernetes-role/status-403`.
The public reply remains generic HTTP 503. This is after the repair boundary and before Sprint
`2.75`'s provisioner-accessor revocation stage.

### Deliverables

- Trace the exact Kubernetes-auth role path and current ordinary provisioner policy projection.
- Add only the missing role capability and preserve the disjoint repair role, no wildcard, and no
  ACL-policy write in the ordinary plan.
- Add structural and closed-classification regressions for the exact authority.
- Deploy the correction and resume Sprint `2.75`'s diagnostic crossing.

### Validation

1. Focused cases prove exact role-path capability, no ACL-policy or wildcard authority, and
   unchanged failure/public-response classification.
2. Warning-clean all-target build, full unit and authority suites, documentation lint, and
   `prodbox dev check` pass before live qualification.
3. The corrected deployment crosses Kubernetes-role write/read-back and reaches Sprint `2.75` or
   registers the next distinct transition.

### Remaining Work

1. ~~Implement the exact policy correction and focused regressions.~~ Done 2026-08-26: the
   provisioner policy derives one exact `auth/kubernetes/role/<canonical-name>` stanza per role in
   the compiled reconcile plan, removes the incomplete `prodbox-*` glob, and gains neither `sudo`
   nor ACL-policy authority. The focused structural case passes 1/1 and proves the ordinary plan
   still owns every canonical role while containing no ACL-policy writes.
2. ~~Run the complete local gate.~~ Done 2026-08-26: all **4653** primary cases, the
   **27/33/29** authority suites, documentation lint, warning-clean all-target build, and canonical
   `prodbox dev check` pass.
3. ~~Deploy, record the exact crossing, and resume Sprint `2.75`.~~ Done 2026-08-26: generation 37
   runs local image `sha256:ba38284e…`, registry digest `sha256:d74c7640…`, and containerd OCI
   manifest `sha256:2ee1cbfc…`, observed and ready 1/1 with zero restarts. It crossed the role
   write/read-back and the protected next cause is Sprint `2.75`'s exact
   `http/initial-list-accessors/status-404`; the public response remains generic HTTP 503.

## Sprint 2.81: Empty Post-Revocation Provisioner Inventory Is LIST 404 [✅ Done]

**Status**: Done and live-proven — generation 39 crossed the exact post-revocation accessor-LIST
HTTP 404 and exposed Sprint `2.82`'s distinct final absence-proof boundary.
**Implementation**: `src/Prodbox/Bootstrap/Broker/ProductionEngine.hs` and focused validation under
`test/unit/BootstrapBrokerEnginePhysical.hs`.
**Deployment qualification**: proven — generation 39 crossed the owned correction under the exact
ready, zero-restart runtime identity recorded below.
**Independent Validation**: pure classification must prove only the two accessor-list operations
admit Vault's empty-collection HTTP 404, while non-list operations and every other typed HTTP
failure remain closed.
**Docs to update**: `documents/engineering/bootstrap_readiness_doctrine.md`,
`documents/engineering/vault_doctrine.md`, `DEVELOPMENT_PLAN/README.md`,
`DEVELOPMENT_PLAN/00-overview.md`, and `DEVELOPMENT_PLAN/system-components.md`.

### Objective

Treat Vault's exact empty token-accessor collection result on the authoritative post-revocation
LIST as successful absence without broadening any non-list operation or masking another failure.

### Live Counterexample (2026-08-26)

Broker generation 38 runs local image `sha256:39be376e…`, registry digest `sha256:6bf24c4a…`, and
containerd OCI manifest `sha256:aedc95fd…`, observed and ready 1/1 with zero restarts. It crossed
Sprint `2.75`'s corrected initial LIST, then the protected diagnostic rendered
`baseline-stage=revoke-provisioner-accessor; provisioner-accessor-revocation-cause=http/post-list-accessors/status-404`.
The public reply remained generic HTTP 503. This is Vault's representation of the empty collection
after the session accessor is already absent; the classifier still treats the post-list result as
an error.

### Deliverables

- Admit exact HTTP 404 as an empty inventory at the post-revocation accessor LIST.
- Preserve successful listing contents, every non-list operation, every other typed HTTP failure,
  exact target/role absence, and all public response bytes.
- Deploy the correction, cross this exact transition, and register any later distinct transition
  before changing it.

### Validation

1. Focused cases prove initial and post-revocation LIST 404 become empty inventories, while a
   non-list operation's 404 and all non-404 failures remain unchanged.
2. Warning-clean all-target build, full unit and authority suites, documentation lint, and
   `prodbox dev check` pass before live qualification.
3. The corrected deployment crosses provisioner-session revocation and reaches exact baseline,
   Authority readiness, and handoff read-back or registers the next distinct transition.

### Remaining Work

1. ~~Implement the narrow classifier correction and focused regression.~~ Done 2026-08-26: exact
   HTTP 404 at the initial and post-revocation accessor LIST operations becomes `Right []`; a
   target-lookup 404 and every other failure retain the closed cause. The focused case passes 1/1.
2. ~~Run the complete local gate.~~ Done 2026-08-26: all **4653** primary cases, the
   **27/33/29** authority suites, documentation lint, warning-clean all-target build, and canonical
   `prodbox dev check` pass.
3. ~~Deploy, record the exact crossing, and resume the retained baseline/Authority/handoff path.~~
   Done 2026-08-26: generation 39 runs local image `sha256:171956cd…`, registry digest
   `sha256:f019969f…`, and containerd OCI manifest `sha256:ad85b11e…`, observed and ready 1/1 with
   zero restarts. It crossed the post-revocation LIST and exposed Sprint `2.82`'s separately
   registered `prove-provisioner-accessor-absent; boundary-unavailable` transition.

## Sprint 2.82: Final Provisioner-Accessor Absence Needs an Exact Cause [✅ Done]

**Status**: Done and live-proven — generation 41 crossed the exact corrected role-wide
accessor-LIST HTTP 404 and entered the next ordered Target Secret Agent chart transition.
**Implementation**: `src/Prodbox/Bootstrap/Broker/Engine.hs`,
`src/Prodbox/Bootstrap/Broker/ProductionEngine.hs`, and focused validation under `test/unit/`.
**Deployment qualification**: proven — generation 41 crossed the owned final-absence transition;
Sprint `2.83` owns the separately registered Target Secret Agent startup counterexample.
**Independent Validation**: pure cause fixtures must exhaust bounded-auditor acquisition,
role-accessor inventory/lookup, inventory construction, and exact-absence outcomes while retaining
generic public reply bytes and no secret-bearing text.
**Docs to update**: `documents/engineering/bootstrap_readiness_doctrine.md`,
`documents/engineering/vault_doctrine.md`, `DEVELOPMENT_PLAN/README.md`,
`DEVELOPMENT_PLAN/00-overview.md`, and `DEVELOPMENT_PLAN/system-components.md`.

### Objective

Replace final provisioner-accessor absence proof's broad boundary failures with one closed,
payload-free protected cause; observe the exact live failure before correcting behavior; and resume
the durable baseline/Authority/handoff path.

### Live Counterexample (2026-08-26)

Broker generation 39 runs local image `sha256:171956cd…`, registry digest `sha256:f019969f…`, and
containerd OCI manifest `sha256:ad85b11e…`, observed and ready 1/1 with zero restarts. It crossed
Sprint `2.81`'s post-revocation empty collection and then rendered
`baseline-stage=prove-provisioner-accessor-absent; boundary-unavailable`; the public reply remained
generic HTTP 503. `proveProvisionerSessionAbsent` still collapses bounded-auditor login, role-wide
accessor LIST and per-accessor lookup, inventory construction, and exact absence into broad
`EngineBoundaryError` classes.

### Deliverables

- Add a closed payload-free cause covering bounded-auditor acquisition/cleanup, accessor LIST and
  policy lookup HTTP classes, inventory construction, and exact absence failure.
- Project the cause only on the protected baseline route while preserving every public response
  class and excluding accessors, subjects, roles, tokens, paths, bodies, and arbitrary text.
- Deploy the diagnostic without changing absence behavior, observe the exact live cause, then
  correct only that evidenced invariant and register any later transition before changing it.

### Validation

1. Focused cases exhaust the closed cause and rendering, preserve public replies, and prove no
   payload-bearing transport detail crosses the diagnostic boundary.
2. Warning-clean all-target build, full unit and authority suites, documentation lint, and
   `prodbox dev check` pass before each live deployment.
3. The diagnostic names an exact final-absence cause; the corrected deployment crosses it and
   reaches baseline completion, Authority readiness, and exact handoff read-back or registers the
   next distinct transition.

### Remaining Work

1. ~~Implement the diagnostic-only closed cause and exhaustive focused proof.~~ Done 2026-08-26:
   21 payload-free causes exhaust bounded-auditor acquisition/cleanup, three HTTP operations and
   four HTTP classes, exact role presence, and inventory construction. The protected-only
   rendering and existing unavailable/ambiguous/refused replies pass 2/2 focused cases; final
   absence behavior is unchanged.
2. ~~Run the complete local gate and deploy the diagnostic without changing absence behavior.~~
   Done 2026-08-26: all **4655** primary cases, the **27/33/29** authority suites, documentation
   lint, warning-clean all-target build, and canonical `prodbox dev check` pass. Generation 40 runs
   local image `sha256:ab468c74…`, registry digest `sha256:56aef500…`, and containerd OCI manifest
   `sha256:ef620d47…`, observed and ready 1/1 with zero restarts. It names exact
   `http/list-accessors/status-404` while retaining the generic public HTTP 503 reply.
3. ~~Correct only the exact live cause, rerun the complete gate, deploy, and resume the retained
   baseline/Authority/handoff path.~~ Done 2026-08-26: the classifier maps only exact role-wide LIST
   HTTP 404 to an empty inventory, retains lookup 404 and every other failure, and passes 2/2
   focused cases. All **4655** primary cases, the **27/33/29** authority suites, documentation
   lint, warning-clean all-target build, and canonical `prodbox dev check` pass. Generation 41 runs
   local image `sha256:52e3d111…`, registry digest `sha256:6be97be0…`, and containerd OCI manifest
   `sha256:0019b7de…`; its Broker Deployment is observed and ready 1/1 with zero restarts. The
   supported reconcile crossed final absence and federated Vault lifecycle before exposing Sprint
   `2.83`'s separately registered Target Secret Agent startup refusal.

## Sprint 2.83: Target Secret Agent Startup Needs an Exact Cause [✅ Done]

**Status**: Done and live-proven — generation 45 forced a fresh baseline, crossed Target Agent
session acquisition, and exposed Sprint `2.84`'s distinct broad handler-construction cause.
**Implementation**: `src/Prodbox/ControlPlane/Runtime.hs`,
`src/Prodbox/ControlPlane/AuthenticatedRuntime.hs`,
`src/Prodbox/ControlPlane/TransitRequestAuthentication.hs`, `src/Prodbox/Vault/Session.hs`,
`src/Prodbox/Vault/Reconcile.hs`, `src/Prodbox/Bootstrap/Broker/Types.hs`,
`src/Prodbox/Bootstrap/Broker/Model.hs`, and focused validation under `test/unit/`.
**Deployment qualification**: proven — generation 45 crossed the corrected receipt-currentness and
session-acquisition transition under the exact ready, zero-restart identity recorded below.
**Independent Validation**: pure rendering and runtime-seam fixtures exhaust the closed startup
stages, prove no arbitrary decoder/HTTP/Vault text crosses stderr, and preserve exit 1 for every
existing failure.
**Docs to update**: `documents/engineering/config_doctrine.md`,
`documents/engineering/distributed_gateway_architecture.md`,
`documents/engineering/bootstrap_readiness_doctrine.md`, `documents/engineering/vault_doctrine.md`,
`DEVELOPMENT_PLAN/README.md`, `DEVELOPMENT_PLAN/00-overview.md`, and
`DEVELOPMENT_PLAN/system-components.md`.

### Objective

Replace the Target Secret Agent's silent startup exits with one closed, payload-free protected
cause; observe the exact deployed refusal before changing behavior; and resume the ordered
Lifecycle Authority and post-unseal handoff path.

### Live Counterexample (2026-08-26)

Generation 41 carries local image `sha256:52e3d111…`, registry digest `sha256:6be97be0…`, and
containerd OCI manifest `sha256:0019b7de…`; the Broker Deployment is observed and ready 1/1 with
zero restarts. The supported reconcile completed federated Vault lifecycle and installed the
Target Secret Agent. Its Pod then entered `CrashLoopBackOff`: the exact entrypoint
`target-secret-agent start --config /etc/target-secret-agent/config/config.dhall` exits 1 in about
one second, emits no current or previous container log, and leaves `handoff_observed=false`.
Config decoding/validation, Vault configuration, mounted authentication resolution, and handler
construction all currently collapse to the same silent exit.

Generation 42 then deployed the diagnostic under local image `sha256:b8fd8c1a…`, registry digest
`sha256:d4b8ce6a…`, and containerd OCI manifest `sha256:5df3c472…`; its Broker Deployment is
observed and ready 1/1 with zero restarts. The protected Target Agent log named exact
`authentication/trust-resolution`. Its standing Vault Kubernetes-auth role was compiled by the
shared `standingRole` helper with namespace `gateway`, while the Pod's exact ServiceAccount lives
in `target-secret-agent`. The supported failed-release cleanup uninstalled the release and verified
absence.

Generation 43 then deployed the namespace correction under local image `sha256:df91ffeb…`,
registry digest `sha256:7575c54b…`, and containerd OCI manifest `sha256:75858447…`. Its Broker
Deployment is observed at generation 43/43, ready 1/1, and zero-restart. The Target Agent still
reports broad `authentication/trust-resolution`, so the namespace mismatch was not the complete
live cause. The remaining diagnostic must distinguish Kubernetes-session acquisition from a
Transit public-key read and classify the latter without carrying response bodies or arbitrary
error text.

Generation 44 deployed the refined diagnostic under local image `sha256:8cfebb18…`, registry
digest `sha256:57d8c3c6…`, and containerd OCI manifest `sha256:f0d3e908…`. Its Broker Deployment is
observed at 44/44, ready 1/1, and zero-restart. The Target Agent names exact
`authentication/session-acquire/forbidden`. The source namespace correction is therefore
necessary, but the retained closed baseline receipt's target list is unchanged and causes the old
role projection to be reused. The correction must make that exact role part of current receipt
identity while admitting the preceding closed target set only as input to a fresh-session restart.

### Deliverables

- Add a closed payload-free cause for every Target Secret Agent startup refusal stage.
- Emit only the closed cause on stderr for that protected in-cluster runtime and preserve every
  existing exit code and startup decision.
- Deploy the diagnostic without changing behavior, observe the exact cause, then correct only that
  evidenced invariant and register any later transition before changing it.

### Validation

1. Focused cases exhaust cause rendering, exclude arbitrary error text and secret-bearing values,
   and prove every pre-existing failure still exits 1.
2. Warning-clean all-target build, full unit and authority suites, documentation lint, and
   `prodbox dev check` pass before each live deployment.
3. The diagnostic names one exact startup cause; the corrected deployment crosses it and reaches
   Lifecycle Authority readiness and exact handoff read-back or registers the next distinct
   transition.

### Remaining Work

1. ~~Implement the diagnostic-only closed cause and focused exhaustive proof.~~ Done 2026-08-27:
   ten nullary causes exhaust config decode/validation, Vault configuration, target identity,
   authentication topology/trust/signer resolution, and three handler-construction stages. Only
   the Target Secret Agent emits the closed cause; every role retains exit 1. Focused cases pass
   2/2 without a startup behavior change.
2. ~~Run the complete local gate and deploy the diagnostic without changing startup behavior.~~
   Done 2026-08-27: all **4657** primary cases, the **27/33/29** authority suites, documentation
   lint, warning-clean all-target build, and canonical `prodbox dev check` pass. Generation 42
   carries the image identities above; its protected log names exact
   `authentication/trust-resolution`, while public process behavior remains exit 1. Supported
   failed-release cleanup verified absence.
3. ~~Refine the broad trust-resolution cause without changing public exit behavior.~~ Done
   2026-08-27: generation 43 live-disproved the namespace hypothesis while retaining the same
   protected broad cause. The refinement preserves typed initial-acquisition, relogin, and
   Transit-read provenance and exhaustively maps session/read failures without response bodies or
   arbitrary error text. Focused Sprint `2.83` cases pass 4/4 and session-boundary cases pass 6/6.
4. ~~Run the complete local gate and deploy the refined diagnostic without changing exit behavior;
   observe one exact closed session or Transit-read cause.~~ Done 2026-08-27: all **4662** primary
   cases, the **27/33/29** authority suites, documentation lint, warning-clean all-target build, and
   canonical `prodbox dev check` pass. Generation 44 carries the image identities above; its Broker
   is observed at 44/44, ready 1/1, and zero-restart, and the protected cause is exact
   `authentication/session-acquire/forbidden`. Supported cleanup uninstalled the failed release,
   verified absence, and returned the unchanged retained root-session receipt.
5. ~~Correct only the exact refined live cause, rerun the complete gate, deploy, and resume the
   retained Lifecycle Authority/handoff path.~~ Done 2026-08-27: the local correction binds only
   `VaultRoleTargetSecretAgent` to namespace `target-secret-agent`; other standing-role bindings are
   unchanged. Focused cases pass 3/3; all **4658** primary cases, the **27/33/29** authority
   suites, documentation lint, warning-clean all-target build, and canonical `prodbox dev check`
   pass, but generation 43 retains broad `authentication/trust-resolution`; do not treat the
   namespace correction as live-proven. Generation 44 proves the current retained receipt omitted
   the role from its currentness identity: add the exact Target Agent standing-role target, admit
   the immediately preceding closed target set only as restart input, and prove a new session ID is
   required before deployment. The append-only target and explicit historical terminal set are
   implemented; the prior CBOR decodes, remains terminal-only, selects a fresh identity, and
   restarts at orphan cleanup while partial and in-progress obsolete receipts remain corrupt. The
   focused custody matrix passes 11/11 and all **4663** primary cases pass; the complete gate also
   passes the **27/33/29** authority suites, documentation lint, warning-clean all-target
   build, and canonical `prodbox dev check`. Generation 45 runs local image
   `sha256:675fe4d4…`, registry digest `sha256:97de22f4…`, and containerd OCI manifest
   `sha256:e9114982…`; its Broker is observed at 45/45, ready 1/1, and zero-restart. The Target Agent
   crosses session acquisition and trust resolution, then names Sprint `2.84`'s separately
   registered broad `handler/boundaries` cause. The refreshed receipt advances from
   `root-session-9420d5a0…` to `root-session-ff34f6c3…` on the same storage generation, and supported
   cleanup uninstalls the failed release and verifies absence.

## Sprint 2.84: Target Secret Agent Handler Construction Needs an Exact Cause [✅ Done]

**Status**: Done and live-proven — generation 47 crossed the corrected tombstone binding and
registered Sprint `2.85`'s distinct readiness transition before any readiness behavior change.
**Implementation**: `src/Prodbox/ControlPlane/Runtime.hs`, the Target Agent production handler
construction boundaries it calls, and focused validation under `test/unit/`.
**Deployment qualification**: proven — generation 47 runs the corrected Target Agent healthy and
zero-restart under the exact replacement identity recorded below.
**Independent Validation**: pure rendering and injected-boundary fixtures exhaust the Target Agent
handler-construction stages, retain no arbitrary error text or secret-bearing value, and preserve
exit 1 for every existing failure.
**Docs to update**: `documents/engineering/config_doctrine.md`,
`documents/engineering/distributed_gateway_architecture.md`, `DEVELOPMENT_PLAN/README.md`,
`DEVELOPMENT_PLAN/00-overview.md`, and `DEVELOPMENT_PLAN/system-components.md`.

### Objective

Replace Target Secret Agent's broad handler-boundary startup refusal with exact closed,
payload-free construction causes; observe the deployed cause before changing behavior; and resume
the ordered Lifecycle Authority and post-unseal handoff path.

### Live Counterexample (2026-08-27)

Generation 45 runs local image `sha256:675fe4d4…`, registry digest `sha256:97de22f4…`, and
containerd OCI manifest `sha256:e9114982…`; its Broker Deployment is observed at 45/45, ready 1/1,
and zero-restart. The Target Agent crosses the corrected Kubernetes session acquisition and Transit
trust registry construction, then exits 1 with protected cause `handler/boundaries`. The existing
cause collapses all production handler-boundary construction failures, so no behavior correction is
licensed yet.

Generation 46 runs local image `sha256:1aed0098…`, registry digest `sha256:2c60063c…`, and
containerd OCI manifest `sha256:5445d006…`; its Broker Deployment is observed at 46/46 and ready
1/1. The diagnostic-only refinement preserves exit 1 and names exact protected cause
`handler/boundaries/tombstone-binding`. Production constructs the tombstone boundary over the
compiled `TargetSesSmtp` sink, whose identity is `ses-smtp`, but passes the independent deployment
cluster ID to `mkTargetGenerationTombstoneBinding`; the constructor correctly refuses that
identity mismatch. This exact crossing licenses only the binding-reference correction.

### Deliverables

- Preserve a closed typed cause at each Target Agent production handler-construction boundary and
  map it to one payload-free startup category.
- Retain the existing exit code, protected-only logging, and prohibition on underlying decoder,
  HTTP/Vault, identity, path, token, or arbitrary handler text.
- Deploy the diagnostic-only refinement, observe one exact cause, then correct only its evidenced
  invariant and register any later transition before changing it.

### Validation

1. Focused fixtures exhaust handler-construction cause rendering and prove arbitrary underlying
   text cannot cross the protected event.
2. Warning-clean all-target build, full unit and authority suites, documentation lint, and
   `prodbox dev check` pass before each live deployment.
3. The corrected deployment crosses handler construction and reaches Lifecycle Authority readiness
   and exact handoff read-back or registers the next distinct transition.

### Remaining Work

1. ~~Trace the Target Agent production handler constructors and implement a diagnostic-only closed
   cause for each failure without changing exit behavior.~~ Done 2026-08-27: target-sink
   compilation, trusted-sink construction, tombstone boundary, tombstone binding, tombstone
   registry, and retained-custody construction each map to a distinct closed cause. No underlying
   error payload crosses the protected event, exit 1 is unchanged, and focused startup cases pass
   3/3.
2. ~~Run the complete local gate and deploy the diagnostic-only refinement.~~ Done 2026-08-27:
   all **4663** primary cases, the **27/33/29** authority suites, documentation lint, and the
   warning-clean all-target build pass, and canonical `prodbox dev check` exits 0. Generation 46
   carries the image identities above; its Broker is observed at 46/46 and ready 1/1, while the
   protected Target Agent log names exact `handler/boundaries/tombstone-binding` with exit 1.
3. ~~Correct only the exact live cause, rerun the complete gate, deploy, and resume the retained
   Lifecycle Authority/handoff path.~~ Done 2026-08-27: the correction derives the tombstone
   manifest reference from the compiled sink rather than the independent deployment cluster ID.
   Focused startup cases pass 4/4, all **4664** primary cases pass, the **27/33/29** authority
   suites pass, the warning-clean all-target build passes, and canonical `prodbox dev check` exits
   0. Generation 47 built local image `sha256:e50bbbe4…`, registry digest
   `sha256:c94cd668…`, and containerd OCI manifest `sha256:5c1065a6…`, but its first Helm attempt
   inherited the interrupted generation-46 release's expired Deployment progress condition and
   failed immediately after creating the new ReplicaSet. The corrected Pod never started, so that
   attempt supplies no behavior evidence. Supported cleanup uninstalled the release and verified
   absence. The clean retry observes the Broker at 47/47 and ready 1/1, and runs the corrected
   Target Agent healthy with zero restarts. The Agent crosses all startup handler construction and
   exposes Sprint `2.85`'s separately registered generic HTTP 503 `not-ready` transition.

## Sprint 2.85: Target Secret Agent Readiness Needs an Exact Cause [✅ Done]

**Status**: Done and live-proven — generation 48 names the target-material dependency family and
registers Sprint `2.86`'s narrower target-and-stage transition before any readiness behavior change.
**Implementation**: `src/Prodbox/ControlPlane/Runtime.hs`,
`src/Prodbox/ControlPlane/RoleReadiness.hs`, `src/Prodbox/ControlPlane/Server.hs`, and focused
validation under `test/unit/`.
**Deployment qualification**: proven — generation 48 runs the diagnostic-only refinement healthy
and zero-restart, and supported cleanup verifies the failed release absent after its bounded Helm
deadline.
**Independent Validation**: pure readiness-state fixtures exhaust the closed Target Agent
classifier, exclude arbitrary dependency details, and preserve the existing `/readyz` status/body
and cached background-observation decision for every state.
**Docs to update**: `documents/engineering/config_doctrine.md`,
`documents/engineering/distributed_gateway_architecture.md`,
`documents/engineering/bootstrap_readiness_doctrine.md`, `DEVELOPMENT_PLAN/README.md`,
`DEVELOPMENT_PLAN/00-overview.md`, and `DEVELOPMENT_PLAN/system-components.md`.

### Objective

Replace Target Secret Agent's generic readiness refusal with one protected closed, payload-free
diagnostic over its existing composed cached facts; observe the deployed cause before changing any
dependency or ordering behavior; and resume the retained Lifecycle Authority and post-unseal
handoff path.

### Live Counterexample (2026-08-27)

Generation 47 runs local image `sha256:e50bbbe4…`, registry digest `sha256:c94cd668…`, and
containerd OCI manifest `sha256:5c1065a6…`. Its clean-state retry observes the Broker at 47/47 and
ready 1/1. The Target Agent starts under that exact local image, stays healthy with zero restarts,
and emits no startup-refusal event, proving the tombstone-binding correction crossed. Its liveness
is HTTP 200 `live`, but readiness stays HTTP 503 `not-ready`. The generic response collapses the
composed target-material, authority-clock, projected-token, retained-authority-epoch,
request-replay-projection, initial, stale, unavailable, and identity-rejected states, so no
readiness correction is licensed yet.

### Diagnostic Deployment Evidence (Generation 48, 2026-08-27)

Generation 48 carries local image `sha256:a7ebe0b3…`, registry digest `sha256:7086549e…`, and
containerd OCI manifest `sha256:a80b64c5…`. Its Broker is ready 1/1 and the Target Agent runs
healthy with zero restarts under that exact tag. The protected event repeatedly names
`readiness/dependency-unavailable/target-material`, so the live counterexample now licenses only a
target-material diagnostic refinement. Helm reaches its bounded progress deadline; supported
cleanup uninstalls the failed release and verifies absence. The retained baseline re-read remains
digest `5791f470…`, root session `root-session-ff34f6c3…`, and storage generation
`vault-a290544e…`. The family still collapses every compiled target plus metadata-read and
metadata-validation failures, so Sprint `2.86` is registered before behavior changes.

### Deliverables

- Classify every Target Agent composed readiness state into a closed payload-free cause without
  retaining dependency detail text.
- Emit that cause only on the protected Target Agent diagnostic surface while preserving the
  current HTTP status/body, probe path, cached-background observation, and readiness decision.
- Deploy the diagnostic-only refinement, observe one exact cause, then correct only its evidenced
  invariant and register any later transition before changing it.

### Validation

1. Focused fixtures exhaust the closed cause vocabulary, exclude arbitrary dependency details, and
   prove `/readyz` remains HTTP 200 `ready` or HTTP 503 `not-ready` exactly as before.
2. Warning-clean all-target build, full unit and authority suites, documentation lint, and
   `prodbox dev check` pass before each live deployment.
3. The corrected deployment reaches Lifecycle Authority readiness and exact handoff read-back or
   registers the next distinct transition.

### Remaining Work

1. ~~Trace the composed Target Agent readiness facts and implement a diagnostic-only protected
   closed cause without changing readiness behavior.~~ Done 2026-08-27: starting/stale and each
   known target-material, authority-clock, projected-token, retained-epoch, and replay-projection
   unavailable/identity-rejected family map to 14 nullary causes with closed `other` fallbacks.
   Dependency detail text is discarded, the resolver returns the original readiness state
   unchanged, and focused protected-diagnostic cases pass 6/6.
2. ~~Run the complete local gate and deploy the diagnostic-only refinement.~~ Done 2026-08-27: all
   **4666** primary cases and the **27/33/29**
   authority suites pass, the warning-clean all-target build passes, and canonical `prodbox dev
   check` exits 0. Generation 48 names exact
   `readiness/dependency-unavailable/target-material`. Helm then reaches its progress deadline;
   supported cleanup uninstalls the release and verifies absence. The retained baseline re-read is
   unchanged at digest `5791f470…`, root session `root-session-ff34f6c3…`, and storage generation
   `vault-a290544e…`.
3. ~~Correct only the exact live cause or register the next distinct transition before changing
   it.~~ Done 2026-08-27: the target-material family still collapses every compiled target and the
   metadata-read versus metadata-validation stages, so Sprint `2.86` is registered before any
   readiness behavior change.

## Sprint 2.86: Target Material Readiness Needs an Exact Target and Stage [✅ Done]

**Status**: Done and live-proven — generation 50 runs the corrected Target Agent 1/1 Ready with zero
restarts and advances the supported reconcile to Lifecycle Authority on 2026-08-27.
**Implementation**: `src/Prodbox/ControlPlane/TargetMaterialEndpoint.hs`,
`src/Prodbox/ControlPlane/Runtime.hs`, and focused validation under `test/unit/`.
**Deployment qualification**: proven — generation 49 supplied the exact target/stage evidence and
generation 50 crossed the corrected readiness boundary before exposing Sprint `2.87`'s distinct
Authority startup failure.
**Independent Validation**: a table over `allTargetMaterialIds` proves every rendered diagnostic is
derived from a closed `TargetSecretId` plus a closed metadata-read/metadata-validation stage, retains
no Vault/HTTP/decoder detail, and leaves each existing readiness observation and HTTP response
unchanged.
**Docs to update**: `documents/engineering/config_doctrine.md`,
`documents/engineering/distributed_gateway_architecture.md`,
`documents/engineering/bootstrap_readiness_doctrine.md`, `DEVELOPMENT_PLAN/README.md`,
`DEVELOPMENT_PLAN/00-overview.md`, and `DEVELOPMENT_PLAN/system-components.md`.

### Objective

Refine only the protected target-material readiness diagnostic to identify the closed compiled
target and whether its cached failure came from the metadata read or metadata validation. Preserve
the dependency verdict, cached observer schedule, `/readyz` status/body, and chart ordering; deploy
before changing behavior.

### Live Counterexample (Generation 48, 2026-08-27)

The exact generation-48 identities and terminal cleanup receipt are recorded in Sprint `2.85`.
The Agent is healthy and zero-restart, and its protected cause repeatedly reports
`readiness/dependency-unavailable/target-material`. A missing target is already a successful
readiness observation, so the failure is a metadata read or validation failure on one of the closed
compiled material targets. The family-only cause cannot choose safely between those cases.

### Exact Diagnostic Evidence (Generation 49, 2026-08-27)

Generation 49 carries local image `sha256:f5ae7a52…`, registry digest `sha256:98a85772…`, and
containerd OCI manifest `sha256:298d60ac…`. Its Broker is ready 1/1 and the Target Agent runs
healthy with zero restarts under that exact identity. The protected event repeatedly names
`readiness/dependency-unavailable/target-material/keycloak-patroni-app/metadata-validation`. A
read-only inspection through the Agent's own standing Vault identity outputs field names only and
proves that target has a positive current KV version with an empty custom-metadata map. That is the
exact pre-receipt legacy document; it is neither missing nor a partially populated receipt. The
readiness-only validator accepts the later eight-field legacy receipt but not this older shape,
which prevents Lifecycle Authority startup before its repair path can run. Helm reaches its bounded
deadline; supported cleanup uninstalls the release and verifies absence. The retained baseline
remains digest `5791f470…`, root session `root-session-ff34f6c3…`, and storage generation
`vault-a290544e…`.

### Deliverables

- Represent the target-material diagnostic with one closed `TargetSecretId` and one closed
  observation stage; no arbitrary target token, Vault path, HTTP body, or decoder detail may enter
  the cause.
- Project the new diagnostic from the same observation pass and return exactly the existing
  `RoleDependencyObservation` for every read/missing/valid/invalid outcome.
- Deploy the diagnostic-only refinement, observe the exact target and stage, then correct only that
  evidenced invariant or register the next distinct transition before changing it.

### Validation

1. Focused pure fixtures exhaust every `allTargetMaterialIds` target across read-unavailable and
   metadata-invalid stages and prove arbitrary underlying details cannot affect rendering.
2. Existing missing/valid/invalid readiness observations and `/readyz` behavior remain unchanged.
3. Warning-clean all-target build, full unit and authority suites, documentation lint, and
   `prodbox dev check` pass before deployment.
4. The corrected deployment reaches Lifecycle Authority readiness and exact handoff read-back or
   registers the next distinct transition.

### Remaining Work

1. ~~Implement the target-and-stage diagnostic projection with unchanged readiness observations.~~
   Done 2026-08-27: the background target-material observation emits a closed compiled target plus
   metadata-read or metadata-validation label only on failure, preserves the prior observation for
   read failure/missing/valid/invalid metadata, rejects arbitrary label tokens, and focused
   protected-diagnostic cases pass 7/7.
2. ~~Run the complete local gate and deploy the diagnostic-only refinement.~~ Done 2026-08-27: all
   **4667** primary cases and the **27/33/29**
   authority suites pass, the warning-clean all-target build and documentation lint pass, and a
   terminal cached `prodbox dev check` rerun exits 0. The first canonical attempt was externally
   terminated with exit 143 during its clean rebuild and is non-proof. Generation 49 names exact
   `keycloak-patroni-app/metadata-validation`; supported cleanup verifies absence and the retained
   baseline unchanged.
3. ~~Admit only the evidenced positive-version/empty-custom-metadata pre-receipt document on the
   readiness-only migration seam, keep proof/Provider observations strict, rerun the complete gate,
   deploy, and resume the retained Lifecycle Authority/handoff path.~~ Done 2026-08-27.

   Local correction 2026-08-27: the readiness-only validator now admits exactly a positive current
   version plus an empty custom-metadata map. Zero-version empty and partial metadata remain
   unavailable; the strict validator used by proof and Provider observations is unchanged. Focused
   protected-diagnostic/readiness cases pass 7/7. The complete correction gate passes all **4667**
   primary cases, the **27/33/29** authority suites, documentation lint, the warning-clean all-target
   build, and canonical `prodbox dev check` exit 0. Generation 50 carries local image
   `sha256:08d712aa…`, registry digest `sha256:66bfe597…`, and containerd OCI manifest
   `sha256:b4a380a9…`; its Target Agent is 1/1 Ready with zero restarts. The same reconcile advances
   to Lifecycle Authority, whose distinct silent startup exit is registered as Sprint `2.87` before
   any Authority behavior change.

## Sprint 2.87: Lifecycle Authority Startup Needs an Exact Cause [✅ Done]

**Status**: Done and live-proven — clean generation 51 reports exact protected cause
`authentication/session-acquire/forbidden` on 2026-08-27.
**Implementation**: `src/Prodbox/ControlPlane/Runtime.hs` and focused validation under `test/unit/`.
**Deployment qualification**: proven — the exact generation-51 Pod executes the diagnostic and
registers Sprint `2.88` before any Vault-role behavior change.
**Independent Validation**: an exhaustive table proves every Authority startup failure family maps
to one closed payload-free label, arbitrary boundary detail cannot affect rendering, non-Authority
roles retain their prior logging, and every startup exit and interpreter decision is unchanged.
**Docs to update**: `documents/engineering/distributed_gateway_architecture.md`,
`documents/engineering/bootstrap_readiness_doctrine.md`, `DEVELOPMENT_PLAN/README.md`,
`DEVELOPMENT_PLAN/00-overview.md`, and `DEVELOPMENT_PLAN/system-components.md`.

### Objective

Give the protected Lifecycle Authority startup path a closed, payload-free diagnostic that
distinguishes configuration, Vault/authentication, primary-store, coordinate, and interpreter
construction boundaries. Preserve every existing startup result, runtime plan, and chart ordering;
deploy the diagnostic before correcting behavior.

### Live Counterexample (Generation 50, 2026-08-27)

Generation 50 carries local image `sha256:08d712aa…`, registry digest `sha256:66bfe597…`, and
containerd OCI manifest `sha256:b4a380a9…`. The corrected Target Agent is 1/1 Ready with zero
restarts, so the supported reconcile enters the Lifecycle Authority Helm step. Its generation-50
Pod reaches `CrashLoopBackOff`, repeatedly terminates with exit 1, and emits no stdout/stderr log.
Source inspection shows configuration, Vault/authentication resolution, primary-store binding,
coordinate construction, and interpreter construction can all produce that unqualified exit. Helm
reaches its 30-minute deadline and the supported command retains the failed release because a
readiness timeout is a non-terminal convergence observation; the next supported reconcile owns
failed-release handling before applying the diagnostic generation.

### Deliverables

- Define one closed Lifecycle Authority startup cause whose constructors cover every startup
  refusal boundary and retain no exception, secret, address, token, HTTP body, or decoder detail.
- Emit that cause only to the protected Authority log and return exactly the prior exit result from
  every branch.
- Deploy the diagnostic-only refinement, observe the exact cause, then correct only that invariant
  or register the next distinct transition before changing it.

### Validation

1. Focused cases exhaust the cause vocabulary, prove unique stable rendering, and prove arbitrary
   underlying failure detail cannot enter a label.
2. Existing Target Agent diagnostics and every role's startup result remain unchanged.
3. Warning-clean all-target build, full unit and authority suites, documentation lint, and
   `prodbox dev check` pass before deployment.
4. The corrected deployment reaches Authority readiness and exact handoff read-back or registers
   the next distinct transition.

### Remaining Work

1. ~~Implement and exhaustively validate the diagnostic-only closed Authority startup cause.~~
   Done 2026-08-27: 35 constructors close configuration, typed authentication, exact known
   primary-store read/field, coordinate, interpreter, and fallback stages. Only Authority emits the
   cause; every branch retains exit 1. Focused protected-diagnostic cases pass 9/9.
2. ~~Run the complete local gate and deploy the diagnostic refinement.~~ Done 2026-08-27.

   Local validation 2026-08-27: focused protected-diagnostic cases pass 9/9, all **4669** primary
   cases pass, the **27/33/29** authority suites pass, the warning-clean all-target build passes,
   documentation lint passes, and canonical `prodbox dev check` exits 0. Diagnostic deployment
   The first generation-51 attempt fails before image publication on an external Hackage
   mirror HTTP 403 for `network-byte-order-0.1.8`; no lifecycle workload changes and the attempt is
   non-proof. The retry publishes local image `sha256:051599eb…`, registry digest
   `sha256:d20fbc2d…`, and containerd OCI manifest `sha256:7ea9db67…`, but the retained failed
   StatefulSet makes Helm fail before a replacement Pod executes: diagnostics still show the old
   generation-50 annotation and image. Supported cleanup uninstalls the release and verifies
   absence. The clean-state retry executes that exact image and reports
   `authentication/session-acquire/forbidden`. It reaches the 30-minute Helm deadline with the
   Authority 0/1 Ready and ten restarts; the supported cleanup explicitly retains the failed
   release because a readiness timeout is a non-terminal convergence observation. Exit 1 is not
   absence evidence, and the next supported reconcile owns failed-release handling.
3. ~~Correct only the exact live cause or register the next distinct transition before changing
   it.~~ Done 2026-08-27: source inspection identifies the independently deployed Authority
   namespace mismatch and Sprint `2.88` is registered before changing it.

## Sprint 2.88: Lifecycle Authority Standing Role Uses the Wrong Namespace [✅ Done]

**Status**: Done and live-proven — the exact corrected generation-52 Pod still reports the same
session-acquire refusal, proving the retained baseline suppressed the Vault-role update and
registering Sprint `2.89` before any receipt behavior changes.
**Implementation**: `src/Prodbox/Vault/Reconcile.hs`, the append-only baseline receipt vocabulary
and exact terminal migration under `src/Prodbox/Bootstrap/Broker/`, and focused validation under
`test/unit/`.
**Deployment qualification**: proven — the clean-state corrected Pod carries the exact local image
and exposes Sprint `2.89`'s distinct retained-receipt transition.
**Independent Validation**: the closed Vault-role inventory proves Lifecycle Authority alone binds
ServiceAccount `prodbox-lifecycle-authority` to namespace `lifecycle-authority`, every sibling role
retains its existing account/namespace/policy/token contract, and no wildcard binding is admitted.
**Docs to update**: `documents/engineering/vault_doctrine.md`,
`documents/engineering/distributed_gateway_architecture.md`,
`documents/engineering/bootstrap_readiness_doctrine.md`, `DEVELOPMENT_PLAN/README.md`,
`DEVELOPMENT_PLAN/00-overview.md`, and `DEVELOPMENT_PLAN/system-components.md`.

### Objective

Correct only Lifecycle Authority's exact standing Kubernetes-auth role namespace from `gateway` to
its deployed `lifecycle-authority` namespace. Preserve its role name, ServiceAccount, policies,
audience, token TTL/class, all sibling bindings, startup diagnostic, and chart order.

### Live Counterexample (Generation 51, 2026-08-27)

Generation 51 carries local image `sha256:051599eb…`, registry digest `sha256:d20fbc2d…`, and
containerd OCI manifest `sha256:7ea9db67…`. Its Target Agent is Ready with zero restarts; the clean
replacement Authority Pod carries that exact local image and repeatedly reports protected cause
`authentication/session-acquire/forbidden`. The Pod uses ServiceAccount
`prodbox-lifecycle-authority` in namespace `lifecycle-authority`, while
`defaultVaultReconcilePlan` constructs `VaultRoleLifecycleAuthority` through `standingRole`, whose
compiled namespace is `gateway`. Vault correctly refuses the foreign namespace identity. The
supported command reaches its 30-minute deadline with Authority 0/1 Ready and ten restarts, exits
1, and explicitly retains the failed release because the timeout is non-terminal convergence; the
next supported reconcile owns that release before applying the correction.

### Deliverables

- Construct only `VaultRoleLifecycleAuthority` through `standingRoleInNamespace` with namespace
  `lifecycle-authority` and the existing `prodbox-lifecycle-authority` policy/account.
- Prove every sibling standing role binding and all token/audience/TTL fields remain unchanged.
- Run the complete local gate, deploy, and register any next distinct transition before changing it.

### Validation

1. Focused inventory cases prove the exact Authority account/namespace/policy tuple and reject the
   former `gateway` namespace without changing siblings.
2. Warning-clean all-target build, full unit and authority suites, documentation lint, and
   `prodbox dev check` pass before deployment.
3. The corrected deployment reaches Authority readiness and exact handoff read-back or registers
   the next distinct transition.

### Remaining Work

1. ~~Implement the exact Authority namespace binding and focused sibling-preservation proof.~~
   Done 2026-08-27: only `VaultRoleLifecycleAuthority` now binds namespace
   `lifecycle-authority`; its account, policy, token class, audience, and TTL remain exact. The
   focused standing-role inventory passes all **20** cases and proves every sibling binding is
   unchanged.
2. ~~Run the complete local gate and deploy the correction.~~ Done 2026-08-27.

   Local predeployment validation 2026-08-27: all **4670** primary cases and the
   **27/33/29** authority suites pass, the all-target build is warning-clean, the pinned formatter
   and HLint (`No hints`) pass, repository/chart/documentation lint and generated-document drift
   checks pass, and `git diff --check` is clean. The first canonical wrapper attempt is externally
   terminated with exit 143 during its Cabal rebuild and is non-proof. After the diagnostic
   reconcile releases `.build/prodbox`, the corrected executable is copied into place and the
   stable canonical `prodbox dev check` rerun exits 0. The first deployment publishes local image
   `sha256:b3ac1a5f…`, registry digest `sha256:339625c3…`, and containerd OCI manifest
   `sha256:11e846e8…`, but the inherited failed StatefulSet makes Helm fail before replacing the
   generation-51 Pod; its annotation and image ID remain `sha256:051599eb…`. That attempt is
   non-proof. Supported cleanup uninstalls the release and verifies absence; a clean-state retry of
   the same exact image creates a replacement Pod whose annotation and image ID both equal local
   `sha256:b3ac1a5f…`. That corrected Pod still reports exact
   `authentication/session-acquire/forbidden`, proving the role document was not reconciled. The
   supported command reaches its 30-minute deadline at 0/1 Ready with 14 restarts, exits 1, and
   retains the release because readiness timeout is non-terminal convergence; the next supported
   reconcile owns it.
3. ~~Resume the ordered Authority/handoff path and correct or register only the next exact
   transition.~~ Done 2026-08-27: Sprint `2.89` is registered before changing retained receipt
   currentness.

## Sprint 2.89: Retained Baseline Suppresses the Lifecycle Authority Role Repair [✅ Done]

**Status**: Done and live-proven — generation 53 advances the root session, reapplies the corrected
role, crosses session acquisition, and registers Sprint `2.90` on the next broad interpreter cause.
**Implementation**: `src/Prodbox/Bootstrap/Broker/Types.hs`,
`src/Prodbox/Bootstrap/Broker/Model.hs`, and focused validation in
`test/unit/BootstrapBrokerCustody.hs`.
**Deployment qualification**: proven — the exact generation-53 Pod crosses the corrected boundary
and names the next independently observed startup family.
**Independent Validation**: append-only codec and state-machine cases prove the exact immediately
preceding closed target list is restart input only, never current; it advances the root-session ID,
re-enters cancellation/accessor cleanup/baseline, rejects partial and in-progress old receipts, and
preserves both older admitted terminal migrations.
**Docs to update**: `documents/engineering/vault_doctrine.md`,
`documents/engineering/bootstrap_readiness_doctrine.md`,
`documents/engineering/distributed_gateway_architecture.md`, `DEVELOPMENT_PLAN/README.md`,
`DEVELOPMENT_PLAN/00-overview.md`, and `DEVELOPMENT_PLAN/system-components.md`.

### Objective

Append one exact Lifecycle Authority standing-role target to the retained root-baseline identity so
the namespace correction cannot be suppressed by the old terminal receipt. Admit only the exact
immediately preceding closed target set as native restart input: select a fresh root-session ID,
run the existing cancellation and root-accessor stable-zero program, and execute a new short-lived
generated-root baseline. Preserve prior constructor tags, the two older terminal migrations, every
in-progress refusal, and the no-host/no-ambient-root boundary.

### Live Counterexample (Generation 52, 2026-08-27)

The clean correction retry creates an Authority Pod whose rollout annotation and runtime image ID
both equal local image `sha256:b3ac1a5f…`; its registry digest is `sha256:339625c3…` and node-local
OCI manifest is `sha256:11e846e8…`. The Pod still exits 1 with exact protected cause
`authentication/session-acquire/forbidden`. `defaultVaultReconcilePlan` now contains the correct
`lifecycle-authority` namespace, but the retained closed baseline receipt remains current because
`BaselineTarget` has no member representing the Lifecycle Authority standing role. The Broker
therefore reuses root session `root-session-ff34f6c3…` and never reapplies that role document.
The supported command reaches its 30-minute deadline at 0/1 Ready with 14 restarts, exits 1, and
retains the release as non-terminal convergence.

### Deliverables

- Append `BaselineLifecycleAuthorityStandingRole` after every existing `BaselineTarget`
  constructor and require it in current baseline receipts.
- Admit the exact pre-append target list only in `RootSessionClosed`, with a fresh session identity
  and the existing restart/cleanup/baseline path; keep partial and in-progress receipts corrupt.
- Prove both older historical closed lists retain their narrow admission, run the complete local
  gate, deploy, and register only the next independently observed transition.

### Validation

1. Test-local old codecs decode to the same existing constructor order and the exact immediately
   preceding list decodes without manufacturing it through current constructors.
2. Currentness, invariant, identity-selection, restart, partial-list, and in-progress cases enforce
   the closed migration and preserve both older migrations.
3. Warning-clean all-target build, full unit and authority suites, documentation lint, and
   `prodbox dev check` pass before deployment.
4. The corrected deployment crosses session acquisition and reaches Authority readiness/handoff or
   registers the next exact transition.

### Remaining Work

1. ~~Implement the append-only target and exact closed-receipt migration with focused proofs.~~
   Done 2026-08-27: `BaselineLifecycleAuthorityStandingRole` is appended after every existing tag;
   the exact pre-append list is admitted only in `RootSessionClosed`, remains non-current, selects a
   fresh identity, and restarts at cancellation. Partial and in-progress old lists remain corrupt;
   both older terminal migrations remain admitted. The focused root-session suite passes all
   **12** cases.
2. ~~Run the complete local gate and deploy the correction.~~ Done 2026-08-27.

   Local predeployment validation 2026-08-27: all **4671** primary cases and the
   **27/33/29** authority suites pass, the all-target build is warning-clean, pinned formatting and
   HLint (`No hints`) pass, repository/chart/documentation lint and generated-document drift checks
   pass, and `git diff --check` is clean. After the generation-52 reconcile releases
   `.build/prodbox`, the new binary is copied into place and canonical `prodbox dev check` exits 0.
   The first deployment publishes local image `sha256:b5917d5a…`, registry digest
   `sha256:e735958f…`, and containerd OCI manifest `sha256:17cc0a57…`. It advances the retained root
   session from `root-session-ff34f6c3…` to `root-session-b46b8cb3…` and completes baseline
   read-back, proving the migration. Helm then inherits the failed generation-52 StatefulSet and
   fails before replacing its `sha256:b3ac1a5f…` Pod, so rollout is non-proof. Supported cleanup
   uninstalls the release and verifies absence; a clean-state retry of the exact generation-53 image
   creates a Pod whose annotation and image ID both equal `sha256:b5917d5a…`. It crosses session
   acquisition and reports the next broad cause `interpreter/construction`. The supported command
   reaches its 30-minute deadline at 0/1 Ready with ten restarts, exits 1, and retains the release
   because readiness timeout is non-terminal convergence.
3. ~~Resume the ordered Authority/handoff path and correct or register only the next exact
   transition.~~ Done 2026-08-27: Sprint `2.90` is registered before changing interpreter behavior.

## Sprint 2.90: Lifecycle Authority Interpreter Construction Needs an Exact Cause [✅ Done]

**Status**: Done and live-proven — the exact generation-54 Pod reports
`interpreter/initial-admission` on 2026-08-27.
**Implementation**: `src/Prodbox/ControlPlane/Runtime.hs` and focused validation under `test/unit/`.
**Deployment qualification**: proven — the exact generation-54 Pod executes the diagnostic and
registers Sprint `2.91` before any initial-admission behavior change.
**Independent Validation**: an exhaustive closed table distinguishes registered-client projection,
initial admission, each bounded value/endpoint/client construction, recovery-plane observer,
admission and signer read-back, target-worker image validation, and authenticated-runtime install;
arbitrary underlying `Text` cannot affect rendering and every branch retains exit 1.
**Docs to update**: `documents/engineering/distributed_gateway_architecture.md`,
`documents/engineering/bootstrap_readiness_doctrine.md`, `DEVELOPMENT_PLAN/README.md`,
`DEVELOPMENT_PLAN/00-overview.md`, and `DEVELOPMENT_PLAN/system-components.md`.

### Objective

Refine only Lifecycle Authority's broad `interpreter/construction` startup cause into a closed,
payload-free cause for every actual construction/read boundary inside
`lifecycleAuthorityRuntimeInterpreter`. Preserve all interpreter inputs, effects, ordering,
readiness, error returns, exit 1, and public behavior; deploy the diagnostic before correcting the
evidenced invariant.

### Live Counterexample (Generation 53, 2026-08-27)

Generation 53 carries local image `sha256:b5917d5a…`, registry digest `sha256:e735958f…`, and
containerd OCI manifest `sha256:17cc0a57…`. Its fresh baseline advances root session
`root-session-ff34f6c3…` to `root-session-b46b8cb3…`. The clean replacement Authority Pod's
annotation and image ID equal that local image; it crosses Kubernetes session acquisition and then
exits 1 with protected cause `interpreter/construction`. Source inspection shows that single label
collapses registered-client projection, initial-admission read, authority scope and bounded
transport/replay values, four endpoint/client pairs, recovery-plane observation, retained admission
and signer reads, target-worker digest validation, and authenticated-runtime installation.
The supported command reaches its 30-minute deadline at 0/1 Ready with ten restarts, exits 1, and
retains the release as non-terminal convergence.

### Deliverables

- Define a closed interpreter-construction cause covering every distinguishable fallible stage and
  retaining no arbitrary `Text`, endpoint, credential, response, or decoder detail.
- Return that cause from the interpreter composition boundary, render it only through the protected
  Authority startup event, and preserve every prior effect/result/exit.
- Run the complete local gate, deploy the diagnostic-only refinement, and correct or register only
  the exact observed cause.

### Validation

1. Exhaustive cases prove every cause has one unique stable rendering and arbitrary underlying
   boundary detail cannot enter it.
2. Existing Authority startup/store/session diagnostics and non-Authority behavior remain exact;
   all interpreter refusal paths still exit 1.
3. Warning-clean all-target build, full unit and authority suites, documentation lint, and
   `prodbox dev check` pass before deployment.
4. The refined deployment names one exact interpreter cause before any behavior correction.

### Remaining Work

1. ~~Implement and exhaustively validate the diagnostic-only interpreter cause.~~ Done 2026-08-27:
   21 constructors close every measured fallible interpreter stage; the interpreter returns only
   that type, the protected startup renderer composes it, and every refusal retains exit 1. The
   focused protected-diagnostic suite passes all **10** cases.
2. ~~Run the complete local gate and deploy the diagnostic refinement.~~ Done 2026-08-27.

   Local predeployment validation 2026-08-27: all **4672** primary cases and the
   **27/33/29** authority suites pass, the all-target build is warning-clean, pinned formatting and
   HLint (`No hints`) pass, repository/chart/documentation lint and generated-document drift checks
   pass, and `git diff --check` is clean. The first canonical wrapper attempt is externally killed
   with exit 137 during its parallel Cabal relink after formatter/HLint pass and is non-proof. With
   13 GiB host memory available, the build is completed to quiescence, the binary is refreshed, and
   the stable canonical `prodbox dev check` rerun exits 0. The first deployment publishes local
   image `sha256:7804e9aa…`, registry digest `sha256:c6cd242d…`, and containerd OCI manifest
   `sha256:7e05304d…`; Vault baseline read-back preserves root session
   `root-session-b46b8cb3…`. Helm encounters the inherited failed generation-53 StatefulSet before
   replacing its `sha256:b5917d5a…` Pod, so the rollout is non-proof. Supported cleanup uninstalls
   the release and verifies absence. The clean-state retry creates a fresh Pod whose annotation and
   runtime image ID both equal `sha256:7804e9aa…`; it reports exact protected cause
   `interpreter/initial-admission`. A transient import-induced node DiskPressure taint clears under
   kubelet ownership before scheduling, with no manual cleanup. The supported command reaches its
   30-minute deadline at 0/1 Ready with four restarts, exits 1, and retains the release because
   readiness timeout is non-terminal convergence.
3. ~~Correct only the exact live cause or register the next distinct transition before changing
   it.~~ Done 2026-08-27: Sprint `2.91` is registered before changing initial-admission behavior.

## Sprint 2.91: Lifecycle Authority Initial Admission Needs an Exact Cause [✅ Done]

**Status**: Done and live-proven — the exact generation-55 Pod reports
`interpreter/initial-admission/registration-unobservable` on 2026-08-27.
**Implementation**: `src/Prodbox/ControlPlane/Runtime.hs` and focused validation under `test/unit/`.
**Deployment qualification**: proven — the exact generation-55 Pod executes the diagnostic and
registers Sprint `2.92` before any registration-observation behavior change.
**Independent Validation**: an exhaustive closed table distinguishes projection-registration
coordinate construction, corrupt/unready/unobservable registration observations, and clean-install
versus migration admission construction; arbitrary observation detail cannot affect rendering and
every branch retains exit 1.
**Docs to update**: `documents/engineering/distributed_gateway_architecture.md`,
`documents/engineering/bootstrap_readiness_doctrine.md`, `DEVELOPMENT_PLAN/README.md`,
`DEVELOPMENT_PLAN/00-overview.md`, and `DEVELOPMENT_PLAN/system-components.md`.

### Objective

Refine only Lifecycle Authority's broad `interpreter/initial-admission` cause into a closed,
payload-free cause for each actual registration-coordinate, observation, and admission-constructor
failure inside `resolveInitialAdmission`. Preserve the observation, mode selection, constructor
inputs, effects, ordering, readiness, exit 1, and public behavior; deploy the diagnostic before
correcting the evidenced invariant.

### Live Counterexample (Generation 54, 2026-08-27)

Generation 54 carries local image
`sha256:7804e9aab3e6d744ff0a14a721467d135fe215ec6aad2386f976e63b8019ad0c`, registry digest
`sha256:c6cd242d1f592b042c065f26a6e8049668947a91e715d9125fd7ce23fc660068`, and containerd OCI
manifest `sha256:7e05304d01cb31b162c4859bfd4d3a7df1d5995802b41935dd067155b797f397`.
After supported failed-release cleanup, its clean Pod's rollout annotation and runtime image ID
both equal the local image. It crosses session acquisition and the outer interpreter diagnostic,
then exits 1 with protected cause `interpreter/initial-admission`. Source inspection shows that
label collapses projection-registration coordinate construction, corrupt/unready/unobservable
registration observations, and separate clean-install/migration admission constructors.

### Deliverables

- Define a closed initial-admission cause covering each distinguishable fallible stage while
  retaining no arbitrary `Text`, coordinate, response, or decoder detail.
- Return that cause from `resolveInitialAdmission`, compose it through the protected interpreter
  diagnostic, and preserve every prior observation, result, effect, and exit.
- Run the complete local gate, deploy the diagnostic-only refinement, and correct or register only
  the exact observed cause.

### Validation

1. Exhaustive cases prove every cause has one unique stable rendering and arbitrary underlying
   observation detail cannot enter it.
2. Existing Authority startup/interpreter diagnostics and non-Authority behavior remain exact;
   every initial-admission refusal still exits 1.
3. Warning-clean all-target build, full unit and authority suites, documentation lint, and
   `prodbox dev check` pass before deployment.
4. The refined deployment names one exact initial-admission cause before any behavior correction.

### Remaining Work

1. ~~Implement and exhaustively validate the diagnostic-only initial-admission cause.~~ Done
   2026-08-27: six constructors close registration-coordinate construction,
   corrupt/unready/unobservable observations, and clean-install/migration construction. The
   protected interpreter cause composes that type without retaining detail or changing an exit.
   The focused protected-diagnostic suite passes all **11** cases. One preceding `--match`
   invocation is non-proof because this Hspec binary accepts `--pattern`; the corrected invocation
   executes the named suite and exits 0.
2. ~~Run the complete local gate and deploy the diagnostic refinement.~~ Done 2026-08-27.

   Local predeployment validation 2026-08-27: the focused protected-diagnostic suite passes all
   **11** cases, all **4673** primary cases pass, and the **27/33/29** authority suites pass. The
   warning-clean all-target build, repository-pinned Fourmolu/HLint (`No hints`),
   repository/chart/documentation lint, generated-document drift, and `git diff --check` pass. An
   unsupported `--match` focused invocation executes no test and is non-proof; the corrected
   `--pattern` invocation exits 0. The first complete wrapper rejects ambient-formatter drift and
   is non-proof. After the pinned write pass, a second wrapper ends during its parallel relink
   without a terminal result and is also non-proof. The build is completed to quiescence, the
   binary is refreshed, and the stable canonical `prodbox dev check` rerun explicitly exits 0.
   The first deployment publishes local image `sha256:15cab9d6…`, registry digest
   `sha256:1637da9f…`, and containerd OCI manifest `sha256:58a38ae0…`; exact baseline read-back
   preserves root session `root-session-b46b8cb3…`. Helm encounters the retained failed
   generation-54 StatefulSet before replacing its `sha256:7804e9aa…` Pod, so rollout is non-proof.
   Supported cleanup uninstalls the release and verifies absence. The clean-state retry creates a
   fresh Pod whose rollout annotation and runtime image ID both equal
   `sha256:15cab9d6aa5fca1fda36b88fbb413faacb7c1728822d2483c4ccff55f44c9bea`. It reports exact
   protected cause `interpreter/initial-admission/registration-unobservable`, proving the deployed
   diagnostic. Repeated multi-gigabyte image imports temporarily cross the kubelet's disk-pressure
   threshold; removal of two exact superseded untagged prodbox images and recoverable prodbox
   Docker build cache restores 34 GiB free, after which kubelet clears its own taint without an
   ad-hoc Kubernetes mutation. The retained data and current generation-55 image are untouched.
3. ~~Correct only the exact live cause or register the next distinct transition before changing
   it.~~ Done 2026-08-27: Sprint `2.92` is registered before changing registration observation.

## Sprint 2.92: Lifecycle Authority Registration Unobservability Needs an Exact Cause [✅ Done]

**Status**: Done and live-proven — the clean exact generation-56 Pod reports
`interpreter/initial-admission/registration-unobservable/store-http` on 2026-08-27.
**Implementation**: `src/Prodbox/ControlPlane/Runtime.hs`,
`src/Prodbox/Lifecycle/ModelBCasTransport.hs`, and focused validation under `test/unit/`.
**Deployment qualification**: proven — the diagnostic-only refinement identifies native store
HTTP as the exact registration-store family and registers Sprint `2.93` before behavior changes.
**Independent Validation**: an exhaustive closed table distinguishes coordinate-authority
rejection, native request failure, non-absence HTTP refusal, a successful read without a version,
envelope-open failure, invalid Model-B version, and the unknown fail-closed remainder; arbitrary
transport, HTTP-body, exception, envelope, and version detail cannot affect rendering and every
branch retains exit 1.
**Docs to update**: `documents/engineering/distributed_gateway_architecture.md`,
`documents/engineering/bootstrap_readiness_doctrine.md`, `DEVELOPMENT_PLAN/README.md`,
`DEVELOPMENT_PLAN/00-overview.md`, and `DEVELOPMENT_PLAN/system-components.md`.

### Objective

Refine only Lifecycle Authority initial admission's
`registration-unobservable` cause into a closed, payload-free cause for every actual unobservable
source between the typed registration coordinate and its Model-B observation. Preserve the native
S3 request, encrypted-object open, observation decoding, mode selection, effects, ordering,
readiness, exit 1, and public behavior; deploy the diagnostic before correcting the evidenced
invariant.

### Live Counterexample (Generation 55, 2026-08-27)

Generation 55 carries local image
`sha256:15cab9d6aa5fca1fda36b88fbb413faacb7c1728822d2483c4ccff55f44c9bea`, registry digest
`sha256:1637da9f691efb225faa364e487c14ab3602f9e723fa9c44b1186be6f9742ac8`, and containerd OCI
manifest `sha256:58a38ae0e2d7da95b1c2e656ded989e1398fdabb79360243bb62372b6f2f8c21`.
After supported failed-release cleanup, its clean Pod's rollout annotation and runtime image ID
both equal the local image. It crosses session acquisition and interpreter construction, then exits
1 with protected cause `interpreter/initial-admission/registration-unobservable`. Source inspection
proves a missing key or bucket is not the cause: native S3 maps HTTP 404 to `Nothing`, the encrypted
object layer preserves `Nothing`, the authority core maps it to `AuthorityObjectMissing`, and the
shared transport maps that to `ModelBMissing`. The broad unobservable arm instead combines the
coordinate-authority guard, native request and non-404 HTTP failures, a successful GET without an
ETag, Transit envelope-open failures, invalid Model-B versions, and an unknown fail-closed
remainder.

### Deliverables

- Define a closed registration-unobservable cause covering every distinguishable fallible source
  while retaining no arbitrary `Text`, endpoint, exception, HTTP response/body, envelope, or
  version detail.
- Derive that cause at the narrowest existing boundaries, compose it through the protected initial
  admission diagnostic, and preserve every prior observation, result, effect, and exit.
- Run the complete local gate, deploy the diagnostic-only refinement, and correct or register only
  the exact observed cause.

### Validation

1. Exhaustive cases prove every cause has one unique stable rendering, classify representative
   inputs for each source, and keep arbitrary underlying detail out of the protected event.
2. Existing Authority startup/interpreter/initial-admission diagnostics and non-Authority behavior
   remain exact; true 404 absence still selects clean-install and every unobservable refusal exits
   1.
3. Warning-clean all-target build, full unit and authority suites, documentation lint, and
   `prodbox dev check` pass before deployment.
4. The refined deployment names one exact registration-unobservable cause before any behavior
   correction.

### Remaining Work

1. ~~Implement and exhaustively validate the diagnostic-only registration-unobservable cause.~~
   Done 2026-08-27: eight constructors close coordinate-authority, native endpoint/request/HTTP,
   successful-read-without-version, envelope-open, invalid-Model-B-version, and unknown failures.
   The original observation detail and every effect remain unchanged internally, while only the
   closed rendering reaches the protected event. The focused suite passes all **12** cases.
2. ~~Run the complete local gate and deploy the diagnostic refinement.~~

   Done 2026-08-27: all **4674** primary cases and the **27/33/29**
   authority suites pass. The all-target build is warning-clean, repository-pinned Fourmolu/HLint
   reports `No hints`, documentation lint and `git diff --check` pass. The supported generation-55
   reconcile then reaches its 30-minute deadline at 0/1 Ready with ten restarts, exits 1, and
   retains the release as non-terminal convergence. Its process releases `.build/prodbox`; the
   binary is refreshed. The first `prodbox dev check` run overlaps the plan's terminal-evidence
   update and is therefore provisional despite exiting 0. Its immediately following
   unchanged-worktree canonical rerun also exits 0. This is not yet deployment proof for the
   Sprint-2.92 diagnostic. Generation 56 publishes local image
   `sha256:6e121bb04049dedad20791686bd6ed572ede82e19001b38583197b40df1316ab`,
   registry digest `sha256:501db8c6b6f1209c696acd7e7a5e7e9b94f27ad354f1ff811a098aeccc95f773`,
   and containerd OCI manifest
   `sha256:0c808831cb3d7526df6b3ce17a1fc12377c5f42ca09a5d09c149b6a755fff9e2`.
   Its first reconcile is non-proof: image-import DiskPressure prevents the replacement Bootstrap
   Broker from scheduling, so the supported command exits 1 before reaching Lifecycle Authority.
   Only superseded untagged prodbox runtime images and recoverable Docker build cache are
   collected; retained application data and the tagged generation-56 image remain. Free space
   rises from 25 GiB to 92 GiB, kubelet clears its own taint without an ad-hoc Kubernetes mutation,
   and the replacement Broker becomes Ready. The next supported reconcile reproduces the exact
   three generation-56 identities and preserves root session `root-session-b46b8cb3…`, then
   classifies the inherited Authority Helm revision as terminal failed state. Its retained Pod has
   the generation-56 runtime image ID but the generation-55 rollout annotation and is non-proof.
   Supported cleanup uninstalls the release, verifies absence, and exits 1. A clean exact-image
   retry creates Pod `84fea149-45b9-4c90-8a81-1ba1a83453aa`; its rollout annotation and runtime
   image ID both equal the generation-56 local image. Its protected event reports exact
   `interpreter/initial-admission/registration-unobservable/store-http`, completing deployment
   qualification. The supported reconcile reaches its 30-minute deadline at 0/1 Ready with ten
   restarts, exits 1, and retains the release because readiness timeout is non-terminal
   convergence.
3. ~~Correct only the exact live cause or register the next distinct transition before changing
   it.~~ Done 2026-08-27: Sprint `2.93` is registered before changing the native store HTTP path.

## Sprint 2.93: Lifecycle Authority Registration Store HTTP Needs an Exact Status Class [✅ Done]

**Status**: Done and live-proven — the clean exact generation-57 Pod reports
`interpreter/initial-admission/registration-unobservable/store-http/authorization` on 2026-08-27.
**Implementation**: `src/Prodbox/Minio/ObjectStoreNative.hs`,
`src/Prodbox/ControlPlane/InClusterAuthorityStore.hs`,
`src/Prodbox/Lifecycle/ModelBCasTransport.hs`, `src/Prodbox/ControlPlane/Runtime.hs`, and focused
validation under `test/unit/`.
**Deployment qualification**: proven — the diagnostic-only refinement identifies authorization as
the exact native S3 response-status class and registers Sprint `2.94` before behavior changes.
**Independent Validation**: an exhaustive closed table distinguishes authentication,
authorization, other client, server, unexpected non-error, and unknown/malformed status classes;
arbitrary numeric status, reason phrase, response body, endpoint, and request detail cannot affect
protected rendering, native 404 remains positive absence, and every refusal retains exit 1.
**Docs to update**: `documents/engineering/distributed_gateway_architecture.md`,
`documents/engineering/bootstrap_readiness_doctrine.md`, `DEVELOPMENT_PLAN/README.md`,
`DEVELOPMENT_PLAN/00-overview.md`, and `DEVELOPMENT_PLAN/system-components.md`.

### Objective

Refine only Lifecycle Authority initial admission's native `store-http` unobservability into a
closed, payload-free response-status class at the narrowest existing store boundary. Preserve the
request, authentication material, signer, policy, response body, observation, mode selection,
effects, ordering, readiness, exit 1, and public behavior; deploy the diagnostic before correcting
the evidenced invariant.

### Live Counterexample (Generation 56, 2026-08-27)

Generation 56 carries local image
`sha256:6e121bb04049dedad20791686bd6ed572ede82e19001b38583197b40df1316ab`, registry digest
`sha256:501db8c6b6f1209c696acd7e7a5e7e9b94f27ad354f1ff811a098aeccc95f773`, and containerd OCI
manifest `sha256:0c808831cb3d7526df6b3ce17a1fc12377c5f42ca09a5d09c149b6a755fff9e2`.
After supported failed-release cleanup, the clean Pod's rollout annotation and runtime image ID
both equal the local image. It crosses session acquisition and interpreter construction, then exits
1 with protected cause `interpreter/initial-admission/registration-unobservable/store-http`. That
family deliberately excludes response detail but still combines authentication, authorization,
other client, server, unexpected non-error, and unknown/malformed status classes, so it does not
yet license a credential, policy, signer, or store correction. The supported reconcile reaches its
30-minute deadline at 0/1 Ready with ten restarts, exits 1, and retains the release because
readiness timeout is non-terminal convergence.

### Deliverables

- Define a closed response-status class covering every distinguishable native store HTTP outcome
  while retaining no arbitrary numeric status, reason phrase, response body, endpoint, request, or
  credential detail.
- Derive the class at the narrowest existing store boundary, compose it through the protected
  initial-admission diagnostic, and preserve every prior observation, result, effect, and exit.
- Run the complete local gate, deploy the diagnostic-only refinement, and correct or register only
  the exact observed response class.

### Validation

1. Exhaustive cases prove every status class has one unique stable rendering and arbitrary status
   and response detail cannot cross the protected event.
2. Native S3 404 remains `Nothing`/`ModelBMissing`; all other existing Authority diagnostics and
   non-Authority behavior remain exact, and every unobservable refusal exits 1.
3. Warning-clean all-target build, full unit and authority suites, documentation lint, and
   `prodbox dev check` pass before deployment.
4. The refined deployment names one exact response-status class before any behavior correction.

### Remaining Work

1. ~~Implement and exhaustively validate the diagnostic-only store-HTTP status class.~~ Done
   2026-08-27: the native boundary owns six closed classes — authentication, authorization,
   other-client, server, unexpected-non-error, and unknown — and the protected initial-admission
   cause nests them below `store-http`. Raw internal error detail and all effects remain unchanged.
   All **15** focused protected/native cases pass.
2. ~~Run the complete local gate and deploy the diagnostic refinement.~~

   Done 2026-08-27: all **4677** primary cases and the **27/33/29**
   authority suites pass. The all-target build is warning-clean, repository-pinned Fourmolu/HLint
   reports `No hints`, and documentation lint plus `git diff --check` pass. The stable
   unchanged-worktree canonical wrapper exits 0. Its full-tree HLint memory peak temporarily
   crosses kubelet MemoryPressure; RAM recovers immediately, but replacement local workloads stay
   Pending until kubelet clears its own taint. This is pre-deployment non-proof, and diagnostic
   deployment follows automatic node and baseline recovery. Kubelet clears the condition with
   roughly 13.5 GiB available. The supported recovery reconcile restores MinIO, Vault, and
   Registry, then publishes generation 57: local image
   `sha256:602d2e869ded871e88ac30f7955770ad112054982dd2aec7b0631153ee412787`,
   registry digest `sha256:8593d6c0d8a12503592020b1f6a53294964da90b4de8b4473c48ddb353ef130c`,
   and containerd OCI manifest
   `sha256:756561c1eb764cada059e822d8a5afed7d010c1af2cfff9654bba820f6287f7b`.
   That exact-image run is at Bootstrap Broker and owns recovery of the retained failed Authority
   release before a clean retry. It unseals Vault, preserves root session
   `root-session-b46b8cb3…`, classifies the inherited revision as terminal failed state, uninstalls
   it, verifies absence, and exits 1. Its retained Pod is still generation 56 and is non-proof. A
   clean retry creates Pod `fb9fa537-7c7c-4c2b-810d-376452362b1f`; its rollout annotation and
   runtime image ID both equal the generation-57 local image. Its protected event reports exact
   `interpreter/initial-admission/registration-unobservable/store-http/authorization`, completing
   deployment qualification. The supported reconcile reaches its 30-minute deadline at 0/1 Ready
   with ten restarts, exits 1, and retains the release because readiness timeout is non-terminal
   convergence.
3. ~~Correct only the exact live cause or register the next distinct transition before changing
   it.~~ Done 2026-08-27: Sprint `2.94` is registered before changing the native store
   authorization path.

## Sprint 2.94: Lifecycle Authority Store Authorization Needs an Exact S3 Error Code [✅ Done]

**Status**: Done — the diagnostic implementation, complete local gate, and exact-image live
deployment identify `invalid-access-key` without changing behavior.
**Implementation**: `src/Prodbox/Minio/ObjectStoreNative.hs`,
`src/Prodbox/ControlPlane/Runtime.hs`, and focused validation under `test/unit/`.
**Deployment qualification**: proven for the diagnostic-only generation-58 image; Authority
readiness and bootstrap-handoff read-back remain Sprint `2.96`'s distinct correction surface.
**Independent Validation**: an exhaustive closed table distinguishes access denial, invalid access
key, signature mismatch, request-time skew, malformed authorization header, expired token, other
well-formed S3 code, and malformed/unknown response; arbitrary code text, response body, resource,
request ID, host ID, endpoint, and credential detail cannot affect protected rendering, and every
refusal retains exit 1.
**Docs to update**: `documents/engineering/distributed_gateway_architecture.md`,
`documents/engineering/bootstrap_readiness_doctrine.md`, `DEVELOPMENT_PLAN/README.md`,
`DEVELOPMENT_PLAN/00-overview.md`, and `DEVELOPMENT_PLAN/system-components.md`.

### Objective

Refine only Lifecycle Authority initial admission's native `store-http/authorization`
unobservability into a closed, payload-free S3 response error-code class at the existing native
store boundary. Preserve the request, authentication material, signer, policy, raw internal error,
observation, mode selection, effects, ordering, readiness, exit 1, and public behavior; deploy the
diagnostic before correcting the evidenced invariant.

### Live Counterexample (Generation 57, 2026-08-27)

Generation 57 carries local image
`sha256:602d2e869ded871e88ac30f7955770ad112054982dd2aec7b0631153ee412787`, registry digest
`sha256:8593d6c0d8a12503592020b1f6a53294964da90b4de8b4473c48ddb353ef130c`, and containerd OCI
manifest `sha256:756561c1eb764cada059e822d8a5afed7d010c1af2cfff9654bba820f6287f7b`.
After supported failed-release cleanup, clean Pod `fb9fa537-7c7c-4c2b-810d-376452362b1f` has rollout
annotation and runtime image ID equal to the local image. It crosses session acquisition and
interpreter construction, then exits 1 with protected cause
`interpreter/initial-admission/registration-unobservable/store-http/authorization`. S3 HTTP 403
still combines access denial, invalid access key, signature mismatch, clock skew, malformed
authorization, expired token, and unknown error-code causes, so it does not yet license a
credential, policy, signer, clock, or store correction.
The supported reconcile reaches its 30-minute deadline at 0/1 Ready with ten restarts, exits 1,
and retains the release because readiness timeout is non-terminal convergence.

### Deliverables

- Define a closed S3 response error-code class covering every distinguishable authorization
  outcome while retaining no arbitrary code, response body, resource, request/host ID, endpoint,
  or credential detail.
- Derive the class at the native store boundary, compose it through the protected initial-admission
  diagnostic, and preserve every prior internal error, observation, result, effect, and exit.
- Run the complete local gate, deploy the diagnostic-only refinement, and correct or register only
  the exact observed S3 error-code class.

### Validation

1. Exhaustive cases prove every S3 error-code class has one unique stable rendering and arbitrary
   response detail cannot cross the protected event.
2. Existing HTTP status classification, native S3 404 absence, Authority diagnostics, and
   non-Authority behavior remain exact; every unobservable refusal exits 1.
3. Warning-clean all-target build, full unit and authority suites, documentation lint, and
   `prodbox dev check` pass before deployment.
4. The refined deployment names one exact S3 error-code class before any behavior correction.

### Remaining Work

1. ~~Implement and exhaustively validate the diagnostic-only S3 error-code class.~~ Done
   2026-08-27: the native boundary owns eight closed classes — access-denied, invalid-access-key,
   signature-mismatch, request-time-skewed, authorization-header-malformed, expired-token, other,
   and malformed-or-unknown — and the protected authorization cause nests them. Raw internal error
   detail and all effects remain unchanged. All **18** focused protected/native cases pass.
2. ~~Run the complete local gate and deploy the diagnostic refinement.~~ Done 2026-08-27.

   Complete local validation 2026-08-27: all **4682** primary cases and the **27/33/29**
   authority suites pass. The all-target build is warning-clean, targeted repository-pinned
   Fourmolu succeeds, pinned HLint reports `No hints`, and documentation lint plus
   `git diff --check` pass. The refreshed canonical wrapper initially retains approximately 11.7 GiB after
   its conformance tier. One run starves RKE2 until the server loses its etcd leader lease and the
   build returns 1 without a compiler diagnostic; a second reaches 5 GiB in 36 seconds and is
   interrupted before repeating the failure. RKE2 disables host swap, so swap refresh supplies no
   usable headroom. Sprint `2.95` closes that physical dependency: the exact canonical gate exits 0
   with its aggregate parent near 94 MiB and Haskell-lint child near 1.08 GiB, while RKE2 PID,
   restart count, and the node's False MemoryPressure timestamp remain unchanged.

   Generation 58 publishes local image
   `sha256:86493048c6c2eb96b19ce25fb0307c8ae17136c315f488998949c5a184bbbe36`,
   registry digest `sha256:662fd6486b27c5bb33e7f8d0013d53db8a5f5dc3d3456574a3dae3d1c11b4582`,
   and containerd OCI manifest
   `sha256:6ed78dc37f5d252b6ecfebf426f180b46659cb45db72ccc60ff3957f7f39625e`.
   Its first reconcile is non-proof: RKE2 restarts during the clean image build, then the inherited
   failed generation-57 StatefulSet fails before replacing Pod `fb9fa537…`, whose rollout
   annotation and runtime image ID remain generation 57. The supported path preserves root session
   `root-session-b46b8cb3…`, uninstalls the release, verifies absence, and exits 1. A clean exact
   generation-58 retry remains. The clean retry creates Pod
   `f1d4cdfc-cf35-4083-8241-462475b0742f`; its `prodbox.io/image-build-id` annotation and runtime
   image ID both equal the generation-58 local image. It reports the exact protected cause
   `interpreter/initial-admission/registration-unobservable/store-http/authorization/invalid-access-key`.
   The supported Helm wait reaches its 30-minute deadline at 0/1 Ready with ten restarts, exits 1,
   and retains the release because readiness timeout is non-terminal convergence.
3. ~~Correct only the exact live cause or register the next distinct transition before changing
   it.~~ Done 2026-08-27: clean generation-58 Pod
   `f1d4cdfc-cf35-4083-8241-462475b0742f` runs the exact local image and reports
   `interpreter/initial-admission/registration-unobservable/store-http/authorization/invalid-access-key`.
   Sprint `2.96` is registered before changing credential ordering. The supported reconcile remains
   in flight and must reach its terminal result before `2.94` closes.

## Sprint 2.95: Canonical Gate Isolates Lint Working Sets Between Phases [✅ Done]

**Status**: Done — sequential lint-leaf processes and strict Haskell-style finding batches bound
the canonical gate on the retained-control-plane host.
**Implementation**: `src/Prodbox/CheckCode.hs` and focused validation under `test/unit/`.
**Independent Validation**: a subprocess-boundary test proves the four exact non-recursive
`dev lint files|docs|haskell|chart` child arms run sequentially, with each process exit before the
next family or warning-clean build, while existing short-circuit results and exact exit propagation remain unchanged; the unchanged canonical
`prodbox dev check` then completes on the live retained-control-plane host without MemoryPressure or
an RKE2 restart.
**Docs to update**: `DEVELOPMENT_PLAN/README.md`, `DEVELOPMENT_PLAN/00-overview.md`,
`DEVELOPMENT_PLAN/system-components.md`, `DEVELOPMENT_PLAN/phase-2-gateway-dns.md`, and
`documents/engineering/code_quality.md`.

### Objective

Bound the canonical quality gate's live heap across phase boundaries. Run its four existing lint
leaves in sequential exact self-child processes, then wait for each process to exit before starting
the next family or Cabal. The OS process-lifetime boundaries reclaim each whole temporary graph even
when the Haskell runtime retains it across an explicit major collection.
Preserve every check, ordering edge, message, exit code, formatter/linter/build argument, and
generated-artifact result.

### Live Counterexample (2026-08-27)

The Sprint-`2.94` canonical gate's parent process reaches approximately 11.7 GiB RSS while HLint is
only approximately 300 MiB. The first terminal attempt pushes the node through severe memory
pressure; RKE2 loses its etcd leader lease, restarts, and the subsequent Cabal subprocess returns 1
without a compiler diagnostic. After the node recovers, a second unchanged attempt reaches 5 GiB
RSS in 36 seconds and is stopped before repeating the control-plane failure. Kernel and
`systemd-oomd` journals contain no OOM kill. Cycling `/swap.img` initially restores capacity, but
RKE2 disables swap during startup, so the gate must correct its own object lifetime rather than rely
on host overcommit. A first correction attempts a major collection after successful conformance;
the live retry still holds 9.28 GiB after Fourmolu starts and is stopped at 1.57 GiB available,
proving the graph remains reachable and requiring the stronger child-process lifetime boundary.
The first child-isolated retry holds the aggregate parent at 93 MiB during file/conformance lint,
then generated-document lint running in that parent grows it to 7.67 GiB. The same lifetime defect
therefore covers every repository-reading lint family, and the child boundary covers all four
existing leaf commands rather than special-casing one implementation.
The Haskell leaf's remaining 9.66-GiB peak is then reproduced under a 6-GiB RTS ceiling, where it
fails with exact heap exhaustion rather than endangering RKE2. Source inspection finds 32
file-reading checks whose lazy finding lists are all retained until a final concatenation. Forcing
each complete finding payload on return reduces the uncapped leaf parent to approximately 1.15 GiB;
HLint peaks near 308 MiB, host available memory remains near 9.7 GiB, and the direct leaf exits 0.

### Deliverables

- Run the current executable's exact `dev lint files`, `docs`, `haskell`, and `chart` child arms;
  each leaf calls its implementation directly and therefore cannot recurse into the aggregate path.
- Wait for each child exit before starting the next lint family or build, making process termination
  the whole-heap reclamation boundary rather than scattering collections through checks.
- Force each Haskell-style check's full finding spine/payload before the next file-reading check, so
  an empty or small result cannot retain the scanned source graph until final concatenation.
- Add a focused ordering/short-circuit regression and run the complete gate on the live host while
  observing parent RSS plus node condition and RKE2 restart count.

### Validation

1. Focused tests prove the exact non-recursive child arguments and successful four-leaf order,
   that a failed child still short-circuits with its exact exit code, and that a lazy finding batch
   is completely forced at its scan boundary.
2. All primary and authority unit suites, documentation lint, warning-clean all-target build, and
   `git diff --check` pass.
3. The exact `./.build/prodbox dev check` command exits 0 without crossing kubelet MemoryPressure or
   restarting RKE2; before/after service identity and node conditions are recorded.

### Remaining Work

1. ~~Implement the single child-process lifetime boundary and focused regression.~~ Done
   2026-08-27: all four existing lint leaves run as sequential non-recursive self-children; all 32
   file-reading Haskell-style result batches are fully forced before the next scan. Both focused
   cases pass.
2. ~~Run the complete local and live-host resource validation, then unblock Sprint `2.94`.~~ Done
   2026-08-27: all **4682** primary cases and the **27/33/29** authority suites pass; direct Haskell
   lint, documentation lint, `git diff --check`, and the warning-clean all-target build pass. The
   exact `./.build/prodbox dev check` exits 0. Its aggregate parent remains near 94 MiB and the
   Haskell-lint child near 1.08 GiB; RKE2 remains PID `3161824`, restart count 3, and MemoryPressure
   False with the same pre-run transition timestamp.

## Sprint 2.96: Lifecycle Authority MinIO Principal Precedes Admission [✅ Done]

**Status**: Done — generation 59 proves the unified IAM Job completes before fresh Authority
admission and the exact dedicated credential performs a signed bucket LIST.
**Implementation**: `src/Prodbox/CLI/Rke2.hs`,
`src/Prodbox/Lib/AwsSubstratePlatform.hs`, and focused validation under `test/unit/`.
**Deployment qualification**: proven on the sprint-owned principal-ordering surface; the separate
foreign readiness probe discovered after admission is registered as Sprint `2.97`.
**Independent Validation**: both pure anchored-plan projections and their executor tables prove the
unified MinIO IAM bootstrap is anchored immediately before Lifecycle Authority, remains after the
observed unsealed-Vault prerequisite, executes exactly once, and cannot reappear after Authority
admission; focused manifest tests preserve the two disjoint principals, exact policies, Vault-only
credential source, and idempotent reconciliation.
**Docs to update**: `documents/engineering/bootstrap_readiness_doctrine.md`,
`documents/engineering/helm_chart_platform_doctrine.md`, `DEVELOPMENT_PLAN/README.md`,
`DEVELOPMENT_PLAN/00-overview.md`, and `DEVELOPMENT_PLAN/system-components.md`.

### Objective

Place the existing unified MinIO IAM reconcile on the dependency edge it serves: after Vault is
unsealed and its credential objects are readable, but before Lifecycle Authority starts and
attempts its first native Model-B observation. Preserve credential bytes, principal identities,
policies, bucket, MinIO and Vault transports, idempotence, Target Secret Agent ordering, and every
later steady-state application step.

### Live Counterexample (Generation 58, 2026-08-27)

Clean Pod `f1d4cdfc-cf35-4083-8241-462475b0742f` executes exact local image
`sha256:86493048c6c2eb96b19ce25fb0307c8ae17136c315f488998949c5a184bbbe36` and reports
`interpreter/initial-admission/registration-unobservable/store-http/authorization/invalid-access-key`.
The unified bootstrap job that creates `prodbox-lifecycle-authority` is anchored as host preparation
for the later full Gateway component and assigned to `PhaseSteady`; the transition executor instead
waits for Lifecycle Authority readiness first. On a clean MinIO principal inventory, that ordering
makes the credential stored in Vault unknown to MinIO by construction.

### Deliverables

- Re-anchor the existing unified MinIO IAM bootstrap before the Lifecycle Authority component in
  both home and AWS substrate plans, and assign the home step to the post-unseal transition executor.
- Keep the step after Vault unseal/readiness, before Authority chart installation/admission, and out
  of the steady executor; retain one execution in the compiled native plan.
- Preserve both Gateway and Authority principal/policy reconciliation, bucket creation, Vault-only
  materialization, exact failure propagation, and idempotent retry behavior.
- Run the complete local gate, deploy the exact correction image, prove that the principal is usable
  at Authority admission, and register rather than absorb any distinct later readiness invariant.

### Validation

1. Focused home and AWS plan tests pin the step's component anchor, exact order after Vault unseal
   and before Lifecycle Authority, and single occurrence; the home test additionally pins
   transition/steady executor ownership.
2. Existing MinIO bootstrap manifest and secret-policy tests remain exact, including both disjoint
   users and least-privilege policies.
3. Full unit and authority suites, warning-clean all-target build, documentation lint,
   `git diff --check`, and the exact `prodbox dev check` pass.
4. A clean exact-image supported reconcile no longer reports `invalid-access-key`; the dedicated
   credential succeeds at a signed LIST, and any distinct later readiness refusal is exact and
   separately owned before the phase closes.

### Remaining Work

1. ~~Implement and locally validate the anchored-order correction once the declared blocker
   closes.~~ Done 2026-08-27: both anchored substrate plans place the existing unified bootstrap
   after unsealed Vault/Target Agent and before Lifecycle Authority; home executes it in the
   transition phase and cannot execute it in steady state. The exact rendered home plan and AWS
   projection pass their order regressions, both home plan goldens are updated, the all-target build
   is warning-clean, and all **4682** primary plus **27/33/29** authority cases pass. The exact
   canonical gate exits 0; RKE2 remains PID `3284819` with zero service restarts and the node's False
   MemoryPressure transition is unchanged. The refreshed binary is `sha256:2b8068bb…`.
2. ~~Deploy the exact correction image and prove the corrected principal ordering.~~ Done
   2026-08-27:
   The first supported attempt publishes generation-59 local/registry/OCI identities
   `sha256:ab3462a9…`, `sha256:4b64aa38…`, and `sha256:34a45bba…`; it completes and removes the
   unified MinIO bootstrap Job before Helm reaches Authority. Helm then observes the inherited
   failed generation-58 revision, so supported cleanup uninstalls the release, verifies absence,
   and exits 1. The clean retry creates fresh exact-image Pod `d0b1f1af…`; it stays live with zero
   restarts, its dedicated Vault credential succeeds at a signed MinIO LIST, and the handoff KV
   observation returns normalized 404. Its remaining readiness refusal is the distinct
   Target-worker HMAC probe registered below as Sprint `2.97`.

## Sprint 2.97: Authority Readiness Must Not Probe Target-Worker Custody [✅ Done]

**Status**: Done on the code-owned surface 2026-08-28 — generation 59 crossed initial admission and
isolated the foreign readiness dependency; the exhaustive correction and complete local gate pass.
**Implementation**: `src/Prodbox/ControlPlane/Runtime.hs` and focused validation under
`test/unit/`.
**Deployment qualification**: proven — generation 61 runs one fresh exact-image Authority Pod
Ready and the same supported reconcile crosses Bootstrap Broker handoff read-back.
**Independent Validation**: a closed pure Authority-readiness dependency inventory contains only
the signed Authority object-store LIST and bootstrap-handoff Vault observation; the Target-worker
custody HMAC cannot re-enter that inventory without changing the exhaustive unit expectation.
**Docs to update**: `documents/engineering/bootstrap_readiness_doctrine.md`,
`documents/engineering/vault_doctrine.md`, `DEVELOPMENT_PLAN/README.md`,
`DEVELOPMENT_PLAN/00-overview.md`, and `DEVELOPMENT_PLAN/system-components.md`.

### Objective

Make Lifecycle Authority readiness observe only dependencies owned by that standing role. Preserve
the signed dedicated-MinIO LIST and bootstrap-handoff Vault observation, while removing the
Target-worker child-custody HMAC probe that the Authority does not use and must not be authorized to
perform.

### Live Counterexample (Generation 59, 2026-08-27)

Fresh exact-image Pod `d0b1f1af-45ef-4714-ab5c-4894126d0e99` remains live with zero restarts after
initial admission. Its exact Vault credential succeeds at a signed `prodbox-state` LIST and its
bootstrap-handoff KV observation returns HTTP 404, which the repository normalizes to absence.
The same Authority session receives HTTP 403 at
`transit/hmac/prodbox-retained-material-commitment` when
`observeTargetChildCustodyDependency` runs. That HMAC and the child-custody KV repository belong to
Target one-shot workers; the Authority runtime has no production caller for either capability.

### Deliverables

- Represent the exact Authority readiness inventory as a closed ADT and traverse it exhaustively.
- Retain the signed Authority object-store LIST and bootstrap-handoff Vault observation.
- Remove the Target-worker custody observation from Authority readiness without adding Transit-HMAC
  or child-custody KV permission to the Authority role.
- Run the complete local gate, deploy the exact correction image, reach Authority Ready, and
  complete the broker's post-unseal handoff read-back.

### Validation

1. A focused pure test pins the exact two-member Authority dependency inventory and its order.
2. Existing Target-worker custody tests retain the commitment-HMAC and child-custody KV policy on
   their present narrow worker identities.
3. Full unit and authority suites, warning-clean all-target build, documentation lint,
   `git diff --check`, and exact `prodbox dev check` pass.
4. A clean exact-image supported reconcile reaches Lifecycle Authority Ready and completes
   Bootstrap Broker handoff acceptance/read-back without widening Authority's Vault policy.

### Remaining Work

1. ~~Implement the closed two-member inventory and focused regression.~~ Done 2026-08-27: the
   runtime traverses the exhaustive object-store/handoff ADT, the exact-list regression and
   Authority-versus-Target-worker policy boundary pass, the warning-clean all-target build passes,
   and all **4683** primary plus **27/33/29** authority cases pass. The refreshed binary is
   `sha256:85609f6d…`; the exact canonical gate exits 0 while RKE2 remains PID `3444040` with zero
   restarts and the node's False MemoryPressure transition remains unchanged.
2. ~~Run the complete local validation.~~ Done 2026-08-27: the warning-clean all-target build,
   full unit/authority suites, documentation lint, diff check, and exact canonical gate all pass.
3. ~~Complete the exact live deployment/read-back proof after Sprint `3.46` corrects the separate
   chart-platform retry defect.~~ Done 2026-08-28.
   The pre-correction generation-59 control reaches its 30-minute Helm deadline with Pod
   `d0b1f1af…` still live, exact-image, zero-restart, and 0/1 Ready. The supported command exits 1
   and retains the release because readiness timeout is non-terminal convergence. Generation 60
   publishes local/registry/OCI identities `sha256:ac4c2d48…`, `sha256:8e0b140b…`, and
   `sha256:ff756571…`, completes the unified MinIO bootstrap, and applies the corrected template;
   the StatefulSet then retains unready generation 59 while reporting generation 60 only as its
   update revision. Stable counterexample `HELM-RETRY-2026-08-28` is owned by Sprint `3.46`.
   Generation 61 then removes that failed release, observes absence, and creates fresh Pod
   `c300d852-c83c-464f-bffe-2865e0fadb80`; its rollout annotation and runtime image ID both equal
   local image `sha256:56c7c3c8…`, it is Ready with zero restarts, and the enclosing reconcile
   crosses the post-unseal handoff into the following Authority Backup component.

## Sprint 2.98: Standing Vault Roles Bind Their Workload Namespaces [✅ Done]

**Status**: Done — locally validated and live-proven 2026-08-28.
**Implementation**: `src/Prodbox/Vault/Reconcile.hs` and focused validation under `test/unit/`.
**Live-proof**: proven.
**Deployment qualification**: pending — Sprint `2.99` owns the separately registered
credential-establishment/startup-order counterexample, so no aggregate cutover is claimed.
**Independent Validation**: an exhaustive standing-role table pins every role to its exact
ServiceAccount, namespace, policy, token type, TTL, and audience; full unit and canonical local
gates require no later phase or live Vault.
**Docs to update**: `documents/engineering/vault_doctrine.md`,
`documents/engineering/helm_chart_platform_doctrine.md`, `DEVELOPMENT_PLAN/README.md`,
`DEVELOPMENT_PLAN/00-overview.md`, and `DEVELOPMENT_PLAN/system-components.md`.

### Objective

Bind each separately deployed standing control-plane role to the Kubernetes namespace that owns its
ServiceAccount. Preserve every policy, role name, ServiceAccount name, token type/TTL, audience,
authentication key, and storage capability.

### Live Counterexample (Generation 61, 2026-08-28)

After Lifecycle Authority becomes Ready and handoff succeeds, fresh Authority Backup Pod
`e8833a15-006b-45f9-a363-80a4527f033b` runs exact local image `sha256:56c7c3c8…`, exits 1, and
produces no log line. A secret-safe read-only diagnostic using its mounted ServiceAccount token
receives HTTP 403 from `auth/kubernetes/login` for role `prodbox-authority-backup`. The chart uses
ServiceAccount `prodbox-authority-backup` in namespace `authority-backup`; Vault's `standingRole`
binds that role to namespace `gateway`. The same helper incorrectly binds Provider Worker and TLS
Retention, whose workloads live in `provider-worker` and `tls-retention`.

### Retained-Receipt Counterexample (Generation 62, 2026-08-28)

Generation 62 publishes exact local/registry/containerd identities `sha256:025367fd…`,
`sha256:89c3c57e…`, and `sha256:48f4c027…`; Lifecycle Authority Pod
`71ef5d35-7249-41f3-bc8c-49eb9ff03050` is exact-image, Ready, and zero-restart. The baseline reports
the unchanged closed root session `root-session-b46b8cb3…`. Fresh exact-image Authority Backup Pod
`932002b9-f495-43ca-84e1-0d4e4dd9fd80` still receives HTTP 403 at Vault Kubernetes login. Stable
counterexample `VAULT-ROLE-SEMANTIC-RECEIPT-2026-08-28` proves that changing an existing baseline
target's desired role body does not invalidate a receipt whose target list is unchanged.

### Deliverables

- Replace every stale default-`gateway` standing-role binding with its exact workload namespace.
- Preserve Lifecycle Authority and Target Secret Agent's already-correct explicit namespace
  bindings and keep Gateway on `gateway`.
- Pin the complete role/namespace/ServiceAccount/policy/token inventory exhaustively so a new role or
  namespace drift cannot pass silently.
- Append one semantic-revision baseline target. Admit only the exact immediately preceding target
  list in a terminal closed root session, mint a fresh session identity, and rerun the complete
  generated-root baseline; partial and in-progress older lists remain corrupt.
- Run the complete local gate, deploy the correction, and cross Authority Backup authentication.

### Validation

1. A focused exhaustive table covers Lifecycle Authority, Provider Worker, Authority Backup, TLS
   Retention, and Target Secret Agent with exact namespaces and unchanged sibling fields.
2. Existing Vault policy and chart ServiceAccount tests remain exact.
3. Focused migration tests prove append-only CBOR compatibility, exact older-closed admission,
   fresh-session restart, and rejection of partial or in-progress older inventories.
4. Warning-clean all-target build, full unit/authority suites, documentation lint,
   `git diff --check`, and exact `prodbox dev check` pass.
5. A fresh exact-image Authority Backup Pod no longer receives Vault-login HTTP 403; any separate
   missing credential or signed-store refusal is recorded before behavior changes.

### Remaining Work

1. ~~Implement and locally validate the exhaustive standing-role namespace correction.~~ Done
   2026-08-28: the five-role exhaustive table pins each exact ServiceAccount, namespace, policy,
   token type, TTL, and audience; the existing standing-policy regression independently pins the
   three corrected workload namespaces. Both focused checks pass, as do all **4685** primary cases,
   the **27/33/29** authority suites, documentation lint, `git diff --check`, and the warning-clean
   all-target build. The exact canonical gate exits 0; RKE2 remains PID `3614880` with zero service
   restarts and the node's False MemoryPressure transition remains unchanged. Refreshed binary
   `sha256:bbc8d886…` is ready for exact-image qualification.
2. ~~Implement and locally validate the append-only semantic-revision target and exact
   older-closed-receipt migration exposed by generation 62.~~ Done 2026-08-28: the new target is
   appended after the exact generation-62 inventory; only that complete predecessor in
   `RootSessionClosed` is admitted for a fresh-identity restart, while its partial and in-progress
   forms remain corrupt. The focused case and complete **13**-case root-session suite pass, as do all
   **4686** primary cases, the **27/33/29** authority suites, documentation lint, `git diff --check`,
   and the warning-clean all-target build. The exact canonical gate exits 0; refreshed binary
   `sha256:2c8c3cd8…` leaves RKE2 PID `3734288`, zero restarts, and the node's False MemoryPressure
   transition unchanged.
3. ~~Deploy the complete correction image and cross Authority Backup authentication.~~ Done
   2026-08-28: generation 63 publishes local/registry/containerd identities
   `sha256:35d921747b56e4f8b60b7cb9fbb9b100b3c941f470e95004dcaf58a860e1ea10`,
   `sha256:104e92a0d763e9ea184befdaac9620721c5239ce0ac160175268c37c7c7d725b`, and
   `sha256:f57fe2ebac1a1a3bd1ef52277428b96bd0619cca49b2a80c6a11d5938cae1db5`.
   The complete baseline rerun closes fresh root session
   `root-session-69894281e01ef19bbce3e644f716f6753977a66d2fa5f36922cba2d429d345b7`.
   Fresh Pod `ffab9243-7b68-4ce5-b28b-4d91e12ede2b` carries the exact rollout annotation and
   runtime image ID; its mounted ServiceAccount token logs into Vault with HTTP 200. The same
   secret-safe diagnostic receives HTTP 404 only when reading the not-yet-materialized
   `aws/authority-backup-store` credential and revokes its diagnostic token with HTTP 204. The
   namespace and retained-receipt defects are therefore closed; the distinct startup-order cycle
   is registered below before behavior changes.

## Sprint 2.99: Authority Backup Starts Before Its Genesis Credential [✅ Done]

**Status**: Done — locally validated and live-proven on its owned startup-cycle surface 2026-08-28.
**Implementation**: `src/Prodbox/ControlPlane/DedicatedAdapterStore.hs`,
`src/Prodbox/ControlPlane/Runtime.hs`, `src/Prodbox/ControlPlane/LocalClient.hs`,
`src/Prodbox/Lib/ChartPlatform.hs`, `src/Prodbox/CLI/Rke2.hs`, and focused validation under
`test/unit/`.
**Live-proof**: proven for desired-state apply, listener startup, and the credential-absent process
boundary; the separately registered Sprint `2.100` TokenRequest refusal precedes credential
materialization and therefore leaves aggregate deployment qualification pending.
**Deployment qualification**: pending — Sprint `2.100` owns the next refusal before the complete
establishment-to-store-ready composition can be exercised.
**Independent Validation**: injected credential loaders and transports prove the missing-to-current
transition without Vault or AWS; the exact Helm-argument table and existing native-plan order prove
release apply, establishment, and final readiness independently of later phases.
**Docs to update**: `documents/engineering/lifecycle_control_plane_architecture.md`,
`documents/engineering/bootstrap_readiness_doctrine.md`,
`documents/engineering/vault_doctrine.md`,
`documents/engineering/helm_chart_platform_doctrine.md`, `DEVELOPMENT_PLAN/README.md`,
`DEVELOPMENT_PLAN/00-overview.md`, and `DEVELOPMENT_PLAN/system-components.md`.

### Objective

Break the Authority Backup genesis cycle while preserving exact capability ownership. Apply the
Adapter release and establish its authenticated listener before its long-lived credential exists;
keep cached readiness false and every S3 effect fail-closed until the Credential Provisioner and
home Target Agent materialize the exact Vault generation; then let the unchanged final
component-readiness step observe the signed store.

### Live Counterexample (Generation 63, 2026-08-28)

Fresh exact-image Authority Backup Pod `ffab9243-7b68-4ce5-b28b-4d91e12ede2b` authenticates to
Vault with HTTP 200 and receives HTTP 404 for `secret/data/aws/authority-backup-store`. Process
startup eagerly reads that path and exits 1. Meanwhile `StepAuthorityBackupChartReady` invokes
Helm with `--wait`, so it cannot return while the Deployment is unready;
`StepEstablishAuthorityBackup`, the sole owner that creates and seals the credential, is the next
step and cannot begin. Even after desired-state apply, its local authenticated client currently
waits on the same credential-backed `/readyz` before invoking establishment. Stable counterexample
`AUTHORITY-BACKUP-GENESIS-ORDER-2026-08-28` fixes the pre-establishment state as credential absent,
listener unavailable, both readiness barriers closed, and zero S3 effects.
The supported generation-63 reconcile reaches Helm's ten-minute Deployment progress deadline at
0/1 Ready with six restarts, exits 1, classifies the revision terminal failed, uninstalls it, and
verifies release absence. Its exact terminal diagnostics preserve Pod UID `ffab9243…`, rollout and
runtime image `sha256:35d92174…`, and the prior secret-safe Vault 200/404/204 observation.

### Deliverables

- Apply only the Authority Backup and Bootstrap Broker releases without Helm's readiness wait when
  they are installed before a dependency they help establish. Keep the bounded wait for every
  other release, including TLS Retention.
- Construct the Authority Backup listener from validated static coordinates without eagerly
  requiring its Vault credential. Acquire and validate the current exact-role credential for each
  readiness probe and S3 operation; never cache plaintext credential material or fall back to
  ambient/host credentials.
- Before the credential exists, answer liveness, keep readiness false, and refuse copy/observe
  effects without issuing S3 traffic. After the same binding observes the credential, use only its
  configured region/bucket/prefix and existing immutable S3 transport.
- Let the establishment-only local Authority Backup transport cross a bounded `/healthz` listener
  barrier rather than the post-establishment `/readyz` barrier. Preserve `/readyz` as the
  credential-backed capability projection used by the later component-readiness step.
- Preserve plan order as release desired-state apply → Authority Backup establishment → in-force
  config reconcile → final Authority Backup component readiness. No credential mutation moves out
  of `StepEstablishAuthorityBackup`.

### Validation

1. A focused deferred-binding test proves construction succeeds with a missing credential,
   readiness is false, copy/observe refuse before S3, and the same binding becomes ready and
   performs exact immutable operations after an injected credential appears.
2. A table proves `helmUpgradeWaitArguments` omits `--wait` for exactly `bootstrap-broker` and
   `authority-backup`, while Lifecycle Authority, Provider Worker, TLS Retention, Target Agent, and
   ordinary chart releases retain the bounded wait.
3. Existing native-plan tests retain the exact Authority Backup apply → establish → final-readiness
   order; a local-client regression pins the Authority Backup `/healthz` establishment barrier;
   and existing TLS tests retain eager credential-backed startup and `/readyz` gating.
4. Warning-clean all-target build, full unit/authority suites, documentation lint,
   `git diff --check`, and exact `prodbox dev check` pass.
5. A fresh exact-image supported reconcile observes one Adapter process remain live while the
   credential is absent, completes establishment through the supported credential boundary, and
   observes that same process Ready with a signed S3 round trip; any later refusal is registered
   separately before behavior changes.

### Remaining Work

1. ~~Implement and locally validate the deferred exact-role Authority Backup binding, liveness
   barrier, and exact pre-establishment Helm wait exception.~~ Done 2026-08-28: focused tests prove
   the same binding refuses before an injected credential, issues no underlying store mutation,
   then loads afresh and completes readiness/put/observe after the credential appears; the exact
   two-release Helm table and seven-role local-probe table pass; and the unchanged plan-order pair
   passes. Targeted HLint reports `No hints`, the affected warning-clean unit build succeeds, and
   all **4688** primary cases pass.
2. ~~Run the complete local gate.~~ Done 2026-08-28: all **4688** primary cases, the
   **27/33/29** authority suites, pinned Fourmolu/HLint (`No hints`), documentation lint,
   `git diff --check`, and warning-clean all-target build pass; the exact canonical
   `prodbox dev check` exits 0. Refreshed binary `sha256:b96e2953…` leaves RKE2 active at PID
   `3845691` with zero restarts and the node's False MemoryPressure transition unchanged at
   `2026-08-27T23:59:22Z`.
3. ~~Deploy the correction and cross the owned Authority Backup startup-cycle boundary on the
   supported path.~~ Done 2026-08-28: generation 64 publishes local/registry/containerd identities
   `sha256:39cb70a5457cc563a65d9d05d3bbc0db8582b193b8ff26a239f99c8927146762`,
   `sha256:94d17cf93acc88206712afe1bba6eeaac7f5619d6bee654c0a7f42658ef2224a`, and
   `sha256:d2248a2d2214ed9d9fc26ec5fc0ef9473648e9a082d6411d9998d4be5bfa1a29`. Fresh Pod
   `d165594e-a178-4a1a-b5cd-30a8edb973f4` carries the exact local image in its rollout annotation
   and runtime image ID, remains Running with zero restarts while the credential is absent, and
   leaves the Helm release `deployed`. Reconcile returns from desired-state apply and enters
   `StepEstablishAuthorityBackup`, proving the Helm, eager-credential, and `/readyz` startup cycle
   closed. Its next refusal is the separately registered TokenRequest lifetime defect below, before
   the provisioner can materialize the credential.

### Closure Record

- The exact two-release no-wait table, deferred per-operation credential loader, and
  Authority-Backup-only `/healthz` client barrier pass locally with the unchanged
  apply→establish→final-readiness graph order.
- The complete local gate passes all **4688** primary cases plus the **27/33/29** authority suites,
  pinned Fourmolu/HLint, documentation and diff checks, and warning-clean all-target build.
- Generation 64 proves the replacement process and release survive the credential-absent state and
  that the supported graph reaches establishment. The distinct 300-second TokenRequest rejection
  is not an Authority Backup startup-cycle failure and is registered before its behavior changes.

## Sprint 2.100: Caller TokenRequest Lifetimes Respect the API Floor [✅ Done]

**Status**: Done — locally validated and live-proven on its caller-token boundary 2026-08-28.
**Implementation**: `src/Prodbox/ControlPlane/LifecycleAuthorityAuthentication.hs` and focused
validation in `test/unit/ControlPlaneVaultSession.hs`.
**Live-proof**: proven — generation 65's operator request authenticates to Lifecycle Authority and
returns the typed missing-generation observation. The separately registered Sprint `2.101`
pre-seed settings inversion precedes credential establishment.
**Deployment qualification**: pending — Sprint `2.101` owns the distinct pre-seed settings
inversion before the complete establishment-to-store-ready composition can be exercised.
**Independent Validation**: a hidden-constructor lifetime smart constructor, exhaustive caller
table, and pure subprocess-output classifier prove the API floor and rejection semantics without a
live cluster or Vault.
**Docs to update**: `documents/engineering/lifecycle_control_plane_architecture.md`,
`documents/engineering/vault_doctrine.md`, `DEVELOPMENT_PLAN/README.md`,
`DEVELOPMENT_PLAN/00-overview.md`, and `DEVELOPMENT_PLAN/system-components.md`.

### Objective

Make an invalid caller-bound Kubernetes TokenRequest lifetime unconstructible and preserve the
difference between request validation and authorization. The operator requests Kubernetes' exact
minimum-valid ten-minute bearer token while its independently issued Vault session remains five
minutes; the test harness retains its already-valid fifteen-minute bearer and Vault lifetimes.

### Live Counterexample (Generation 64, 2026-08-28)

The bootstrap-core ServiceAccount `prodbox-control-plane-operator`, its self-token Role, and its
RoleBinding all exist. An impersonated read-only `kubectl auth can-i create` check for that exact
subject, namespace, ServiceAccount, and `token` subresource answers `yes`. The immediately following
supported TokenRequest refuses, and source projection fixes its requested duration at `5m` (300
seconds). Kubernetes' TokenRequest validator defines `MinTokenAgeSec = 10 * 60` and rejects a smaller
`expirationSeconds`, so the request is invalid rather than unauthorized. The current
`ExternalCallerTokenRequestRefused` arm nevertheless makes every non-zero TokenRequest an
authorization refusal. Stable counterexample `TOKENREQUEST-MINIMUM-TTL-2026-08-28` is the exact
300-second request plus successful self-token authorization and the resulting validation rejection.

### Deliverables

- Introduce a hidden-constructor Kubernetes TokenRequest lifetime with a smart constructor that
  refuses fewer than 600 seconds. Render `kubectl --duration` only from that validated value.
- Make the exhaustive external-caller table select ten minutes for
  `LifecycleAuthorityOperator` and fifteen minutes for `LifecycleAuthorityTestHarness`. Do not
  change either Vault Kubernetes-auth role's five-/fifteen-minute issued-session TTL.
- Split TokenRequest failure into closed payload-free validation, authorization, API-unreachable,
  context-unavailable, and unclassified causes. Only the authorization arm maps to
  `VaultSessionForbidden`; invalid, unobserved, and unknown request causes never masquerade as RBAC
  denial, and no Kubernetes response body enters the public/protected rendering.
- Retain exact ServiceAccount read-back, self-token eligibility, explicit impersonated subject,
  home kubeconfig, bounded subprocess, token-shape validation, and every downstream Transit/Vault
  authentication invariant.

### Validation

1. Pure lifetime cases refuse 0 and 599 seconds, admit 600 and the fifteen-minute value, and render
   the exact seconds passed to `kubectl`.
2. The exhaustive caller table pins operator/harness namespace, ServiceAccount, impersonated
   subject, minimum-valid TokenRequest lifetime, and unchanged Vault-role TTLs.
3. Pure subprocess-output cases distinguish Kubernetes invalid-request, authorization-denied,
   API-unreachable, context-unavailable, unclassified failure, unavailable subprocess, and
   malformed success without retaining the supplied diagnostic in any error constructor or
   rendering.
4. Warning-clean all-target build, full unit/authority suites, documentation lint,
   `git diff --check`, and exact `prodbox dev check` pass.
5. A fresh exact-image supported reconcile mints the operator token and receives an authenticated
   Lifecycle Authority response. Any later refusal before establishment/store readiness is
   registered separately before behavior changes.

### Remaining Work

1. ~~Implement the validated lifetime and closed rejection classifier with focused tests.~~ Done
   2026-08-28: the hidden constructor refuses 0/599 seconds and admits 600/900; the exhaustive
   caller table renders those exact seconds while independently pinning the unchanged `5m`/`15m`
   Vault-role TTLs. The payload-free classifier distinguishes invalid, authorization, API,
   context, unclassified, subprocess, and malformed-token outcomes; only authorization maps to
   forbidden, and unclassified cannot claim the authority answered. Focused cases pass 3/3 plus
   the prior authority-reached regression 1/1; targeted HLint reports `No hints` and the affected
   warning-clean build passes.
2. ~~Run the complete local gate.~~ Done 2026-08-28: all **4690** primary cases and the
   **27/33/29** authority suites pass; pinned Fourmolu/HLint, documentation lint, `git diff
   --check`, warning-clean all-target build, and exact canonical `prodbox dev check` exit 0.
   Refreshed binary
   `sha256:0042eea999dd2e8e1b2c2608487bea8ec63519350e72248294813b841a97a2dd` leaves RKE2 active
   with zero service restarts and the node's False MemoryPressure transition unchanged at
   `2026-08-27T23:59:22Z`.
3. ~~Deploy the exact correction and cross the caller-token boundary on the supported path.~~ Done
   2026-08-28: generation 65 publishes local/registry/containerd identities
   `sha256:40d8980aa4e601347bac31ed7e9c8daa909a84092b233e6476941679d6c1506d`,
   `sha256:ddfa34edad155a10f6c653e88bee79c830cd2a5866e6c49c44ccc6d29b5f36fe`, and
   `sha256:0d1d338b64f7e75221738d7120e2380a3f38c1aab5f52e172354249f3d6895d1`.
   Fresh Adapter Pod `8c8cc93c-5f99-4d6e-96bc-71f9c0171b03` carries the exact local image in its
   rollout annotation and runtime image ID, remains Running with zero restarts, and leaves its
   release `deployed`. The operator's request authenticates to Lifecycle Authority and returns the
   typed missing-generation observation instead of the former invalid-duration refusal. The
   separately registered pre-seed settings inversion below stops the graph before credential
   establishment; it is not a caller-token failure.

### Closure Record

- The lifetime constructor, exhaustive caller table, closed payload-free failure classification,
  and complete local gate prove the code-owned correction.
- Generation 65 proves the exact operator caller token is minted, exchanged for the bounded Vault
  session, and accepted by Lifecycle Authority far enough to return its typed missing config
  observation. The new failure is after successful authentication and is registered separately.

## Sprint 2.101: Authority Backup Establishment Uses the Pre-Seed Proposal [✅ Done]

**Status**: Done — locally validated and live-proven on its pre-seed settings surface 2026-08-28.
**Implementation**: `src/Prodbox/CLI/Rke2.hs` and focused validation in `test/unit/Main.hs`.
**Live-proof**: proven — generation 66 passes the formerly terminal missing-generation load and
enters the authenticated Authority Backup transport. Sprint `2.102` owns the distinct no-wait
port-forward convergence refusal before credential establishment.
**Deployment qualification**: pending — Sprint `2.102` owns the distinct dead-forward retry defect
before the complete establishment-to-store-ready composition can be exercised.
**Independent Validation**: a structural call-site regression proves that pre-seed establishment
receives the already validated Tier-0 settings and contains no steady-state loader call; the
existing anchored-order table proves config CAS and in-force loading remain later barriers.
**Docs to update**: `documents/engineering/lifecycle_control_plane_architecture.md`,
`documents/engineering/vault_doctrine.md`, `DEVELOPMENT_PLAN/README.md`,
`DEVELOPMENT_PLAN/00-overview.md`, and `DEVELOPMENT_PLAN/system-components.md`.

### Objective

Remove the clean-install settings inversion without moving authority. Authority Backup genesis
uses the same validated Tier-0 proposal that compiled the transition; only after backup admission
does the existing config-CAS step establish and read back generation 1, after which the normal
in-force loader becomes eligible for final component readiness and steady reconciliation.

### Live Counterexample (Generation 65, 2026-08-28)

The corrected 600-second operator TokenRequest authenticates successfully and Lifecycle Authority
returns `ConfigObservationMissing`. `StepEstablishAuthorityBackup` then renders that legitimate
state as “Lifecycle Authority config is absent” because
`requireEstablishedAuthorityBackupAdmission` calls `validateAndLoadSettings`. Yet the anchored
component order deliberately places `StepReconcileInForceConfig` after establishment, so no
in-force generation can exist on the first pass. Stable counterexample
`PRESEED-SETTINGS-INVERSION-2026-08-28` is the exact absent observation plus the plan relation
`establish < config-CAS < load-in-force` and zero credential-establishment effects.

### Deliverables

- Pass the already validated bootstrap settings into the Authority Backup establishment action;
  do not call the steady-state settings loader on this pre-seed step.
- Preserve the anchored desired-state apply → establishment → config CAS → in-force load/final
  readiness order and every existing Authority/Provisioner/Target Agent/Adapter boundary.
- Keep the filesystem value proposal-only: config CAS and read-back remain the sole transition
  that makes it authoritative, and all later steady steps consume only the in-force projection.
- Add a structural regression that fails if pre-seed establishment reaches the in-force loader or
  if the later config/readiness order drifts.

### Validation

1. A focused source-ownership case proves pre-seed establishment consumes the supplied validated
   settings and contains no in-force settings read.
2. Existing plan-order cases retain Authority Backup apply → establish → config CAS → load
   in-force/final readiness, and settings-source tests retain the post-seed authority loader.
3. Warning-clean all-target build, full unit/authority suites, documentation lint,
   `git diff --check`, and exact `prodbox dev check` pass.
4. A fresh exact-image supported reconcile crosses the pre-seed settings boundary and enters
   Authority Backup establishment. Any later refusal is registered separately before behavior
   changes.

### Remaining Work

1. ~~Implement the pre-seed settings injection and focused regression.~~ Done 2026-08-28: the
   establishment helper now requires the transition's validated settings value and contains no
   steady-state loader call. The focused structural source-ownership case and the independent
   anchored apply → establish → config-CAS → load-in-force order case each pass 1/1; targeted
   HLint reports `No hints` and the affected warning-clean unit build succeeds.
2. ~~Run the complete local gate.~~ Done 2026-08-28: all **4691** primary cases and the
   **27/33/29** authority suites pass; pinned Fourmolu/HLint (`No hints`), documentation lint,
   `git diff --check`, warning-clean all-target build, and exact canonical `prodbox dev check`
   exit 0. Refreshed binary
   `sha256:c537dbb83575f625729ba656236c6a970347f50e5cb83cd4be5e0cfefec38972` leaves RKE2 active at
   PID `4089966` with zero service restarts and the node's False MemoryPressure transition
   unchanged at `2026-08-27T23:59:22Z`.
3. ~~Deploy the exact correction and cross the pre-seed settings boundary on the supported path.~~
   Done 2026-08-28: generation 66 publishes local/registry/containerd identities
   `sha256:ee24805f81a1fbd20f88999996cd6b668b577586e1413dba07748247775da568`,
   `sha256:8dcdbc64a8b943d55342ce323d99c3c7a47db9074a63d04e4e906c9e6b8a958e`, and
   `sha256:fd7143da52d8d3ea32bd7d02d14264e331bb49e87d4bfb6fe4183b7bd7c2ef55`.
   Fresh exact-image Adapter Pod `60c66ae4-ea89-4081-b5b3-a6cf7699dda0` becomes Running with zero
   restarts and leaves its release `deployed`. Reconcile no longer renders the legitimate absent
   generation as a settings error and enters the authenticated Adapter transport. The separately
   registered dead-forward refusal below occurs before credential establishment and is not a
   settings-source failure.

### Closure Record

- The establishment helper structurally receives the transition's validated Tier-0 settings and
  contains no in-force loader; the exact anchored order remains apply → establish → config CAS →
  in-force load.
- The complete local gate passes all **4691** primary cases plus the **27/33/29** authority suites,
  pinned format/lint/docs/diff checks, and warning-clean all-target build.
- Generation 66 crosses the former missing-generation failure. The next failure is inside the
  separately registered Adapter port-forward liveness boundary.

## Sprint 2.102: Authority Backup Liveness Retries the Disposable Forward [✅ Done]

**Status**: Done and live-proven — generation 67 starts fresh forwarding children after the
no-wait Pod appears and exposes Sprint `2.103`'s distinct readiness-filtered Service coordinate.
**Implementation**: `src/Prodbox/ControlPlane/LocalClient.hs` and focused validation in
`test/unit/Main.hs`.
**Live-proof**: proven — generation 67 crosses the exited-first-child condition; the later terminal
cause is independently reproduced with a live but not-ready Service endpoint.
**Deployment qualification**: proven — the owned dead-forward counterexample passes under the
exact generation-67 identity; Sprint `2.103` owns the separately registered routing cycle before
the larger establishment-to-store-ready composition can be qualified.
**Independent Validation**: an injected start/probe/cleanup loop proves each pending liveness
observation retires its process before a fresh attempt and that terminal/client results never
repeat; it requires no cluster or Vault.
**Docs to update**: `documents/engineering/lifecycle_control_plane_architecture.md`,
`documents/engineering/helm_chart_platform_doctrine.md`, `DEVELOPMENT_PLAN/README.md`,
`DEVELOPMENT_PLAN/00-overview.md`, and `DEVELOPMENT_PLAN/system-components.md`.

### Objective

Make the intentionally no-wait Authority Backup rollout convergent at its real process boundary.
Retry a fully bracketed Service port-forward plus one `/healthz` observation, rather than retaining
one child that may have exited before any Pod existed and retrying HTTP against its dead socket.

### Live Counterexample (Generation 66, 2026-08-28)

Helm applies revision 3 without waiting, then returns before the replacement Pod exists.
`kubectl port-forward service/authority-backup` exits, but `waitUntilStartupProbe` performs all 240
HTTP attempts against that now-unbound loopback port. During that budget, fresh exact-image Pod
`60c66ae4-ea89-4081-b5b3-a6cf7699dda0` starts and remains Running with zero restarts, yet no new
forward is created and the command exits with `LocalAuthorityBackupLivenessFailed` connection
refused. Stable counterexample `DEAD-PORT-FORWARD-2026-08-28` is the exited first child, later live
Pod, 240 dead-socket probes, and zero Adapter calls.

### Deliverables

- Factor the Authority Backup local client into one bracketed start → single `/healthz` probe →
  authenticated action attempt and one bounded outer convergence loop.
- Retry only the pre-action liveness failure. Process-start, kubeconfig, port reservation, client
  construction, and every result after the authenticated action begins remain terminal and are
  never repeated.
- Clean each failed child before the next attempt, keep the successful child alive through the
  action, retain the loopback/exact Service/home-kubeconfig constraints, and preserve `/healthz` as
  the sole pre-credential predicate.
- Add injected cases for fail/fail/succeed cleanup order, terminal no-retry, exhausted exact last
  cause, and successful-action exactly once.

### Validation

1. The injected lifecycle table proves a fresh start and cleanup per pending observation, bounded
   exhaustion, no retry of terminal setup failures, and exactly-once action after liveness.
2. Existing role-path and endpoint tests retain `/healthz` only for Authority Backup and `/readyz`
   for all other role clients.
3. Warning-clean all-target build, full unit/authority suites, documentation lint,
   `git diff --check`, and exact `prodbox dev check` pass.
4. A fresh exact-image supported reconcile establishes the Authority Backup credential, commits
   and reads back the in-force config, and observes the same Adapter process Ready through its
   signed S3 round trip. Any later refusal is registered separately before behavior changes.

### Remaining Work

1. ~~Implement the bracketed-forward convergence loop and focused regressions.~~ Done 2026-08-28:
   one attempt brackets start → one `/healthz` probe → action → cleanup, and only
   `LocalAuthorityBackupLivenessFailed` repeats after cleanup. The injected lifecycle table proves
   fail/fail/succeed ordering, cleanup-before-delay, terminal setup exactly once, exact exhausted
   last cause, and successful action exactly once; the existing role-path case independently keeps
   `/healthz` exclusive to Authority Backup. Both focused cases pass 1/1, targeted HLint reports
   `No hints`, and the affected build passes under `-Werror`.
2. ~~Run the complete local gate.~~ Done 2026-08-28: all **4692** primary cases and the
   **27/33/29** authority suites pass; the repository-specific style suite passes all **18** cases;
   pinned Fourmolu/HLint (`No hints`), documentation lint, `git diff --check`, warning-clean
   all-target build, and exact canonical `prodbox dev check` exit 0. Refreshed binary
   `sha256:96719d71c815b16bb474f5d7e1d84b2abadbed4b868eb2e5a7b7f23667d66cb0` leaves RKE2 active at
   PID `4193989` with zero service restarts and the node's False MemoryPressure transition
   unchanged at `2026-08-27T23:59:22Z`.
3. ~~Deploy the exact correction and cross the dead-forward boundary on the supported path.~~ Done
   2026-08-28: generation 67 publishes local/registry/containerd identities
   `sha256:066fda4906fb1639d2738e429a0d2b933a26cfd9e0b0d74e5f70dc15a7059a06`,
   `sha256:751db6d75d6bac984b78ae38d6118824ebe05bacacb0dec4ec0dd1ee809f9d3f`, and
   `sha256:08f3602ad98bdd1b3ebedbdba0aa664d15e9efb27c9e4d83a4d2a76b8feb7ba5`.
   Fresh exact-image Pod `1a125149-a0fb-4e77-a245-f55052ea14fa` appears after apply and remains
   Running with zero restarts; the outer loop starts fresh children after it exists. The next exact
   refusal is separately registered as Sprint `2.103`, because the live Pod remains deliberately
   absent from ready Service endpoints until genesis supplies its store credential.

### Closure Record

- The injected lifecycle proof and complete local gate establish bounded fresh-child retry,
  cleanup-before-retry, terminal failure preservation, and exactly-once action semantics.
- Generation 67 crosses the dead first child with the exact deployed image. The next failure is a
  different Kubernetes forwarding coordinate and is registered below before correction.

## Sprint 2.103: Authority Backup Genesis Uses the Pre-Readiness Workload Coordinate [✅ Done]

**Status**: Done and live-proven — generation 68 reaches the exact not-ready Pod through its
Deployment; Sprint `2.104` owns the distinct pre-probe child-startup handshake.
**Implementation**: `src/Prodbox/ControlPlane/LocalClient.hs` and focused validation in
`test/unit/Main.hs`.
**Live-proof**: proven — exact-image Pod `40e18d8a-9469-47e0-8049-f1676da61e2e` answers
`/healthz` 200 through the Deployment and `/readyz` 503 while its Service endpoint is not ready.
**Deployment qualification**: proven — the owned Service-versus-Deployment routing counterexample
passes under generation 68; Sprint `2.104` owns the separately registered startup timing boundary.
**Independent Validation**: a pure command-shape/compiled-coordinate regression proves only the
Authority Backup pre-readiness client targets its exact Recreate Deployment; sibling steady
clients retain their Services and the existing injected retry lifecycle remains independently
green.
**Docs to update**: `documents/engineering/lifecycle_control_plane_architecture.md`,
`documents/engineering/helm_chart_platform_doctrine.md`, `DEVELOPMENT_PLAN/README.md`,
`DEVELOPMENT_PLAN/00-overview.md`, and `DEVELOPMENT_PLAN/system-components.md`.

### Objective

Break the genesis readiness cycle at the routing boundary. The host client reaches the running
Authority Backup process through the exact Deployment long enough to prove `/healthz` and perform
the authenticated establishment action; the Service remains readiness-filtered and remains the
steady in-cluster route after the credential-backed store probe makes `/readyz` succeed.

### Live Counterexample (Generation 67, 2026-08-28)

Generation 67's fresh exact-image Pod is Running with zero restarts and its listener is live. Its
credential-backed readiness observer correctly returns `/readyz` 503 before establishment, so the
Service EndpointSlice marks the Pod `ready: false` and `serving: false`.
`kubectl port-forward service/authority-backup` consequently exits without a selectable ready Pod
and the supported command exhausts with `LocalAuthorityBackupLivenessFailed` connection refused.
A read-only `kubectl port-forward deployment/authority-backup` to the same Pod returns `/healthz`
200 (`live`) and `/readyz` 503 (`not-ready`). Stable counterexample
`NOT-READY-SERVICE-ENDPOINT-2026-08-28` is that exact endpoint state and two-sided probe result.

### Deliverables

- Change only the Authority Backup genesis forward from `service/authority-backup` to the compiled
  `deployment/authority-backup` coordinate; retain the home kubeconfig, loopback binding, compiled
  port, bounded disposable-forward retries, and authenticated action lifetime.
- Pin the chart's existing `Recreate` strategy and exact Deployment identity in validation so the
  pre-readiness selection cannot overlap old and new Adapter generations silently.
- Preserve Services for Lifecycle Authority, Provider Worker, Target Secret Agent, TLS Retention,
  and steady in-cluster Authority Backup calls; do not publish not-ready endpoints or weaken the
  Adapter's `/readyz` store predicate.
- Deploy the correction and register any later distinct refusal before changing it.

### Validation

1. Focused command-shape cases prove Authority Backup alone forwards its Deployment while every
   sibling host client retains its Service and the chart retains `Recreate`.
2. The Sprint `2.102` injected lifecycle table remains green, including fresh-child cleanup,
   terminal failure, bounded exhaustion, and exactly-once action behavior.
3. Warning-clean all-target build, full unit/authority suites, documentation lint,
   `git diff --check`, and exact `prodbox dev check` pass.
4. A fresh exact-image supported reconcile reaches the live pre-readiness Pod, establishes the
   Authority Backup credential, commits/reads back config, and observes signed-store readiness.
   Any later refusal is registered separately before behavior changes.

### Remaining Work

1. ~~Implement the exact Deployment forwarding coordinate and focused structural regression.~~
   Done 2026-08-28: Authority Backup alone compiles to `deployment/authority-backup`; the four
   sibling host clients retain exact Service targets, and the chart remains `Recreate`. The focused
   command-shape case and retained Sprint `2.102` lifecycle case pass 1/1 each, targeted HLint
   reports `No hints`, and the warning-clean all-target build succeeds.
2. ~~Run the complete local gate.~~ Done 2026-08-28: all **4693** primary cases and the
   **27/33/29** authority suites pass; documentation lint, `git diff --check`, and exact canonical
   `prodbox dev check` exit 0. Refreshed binary
   `sha256:175cda963a80da5f685cecc61df296b9dedf65f567c2524cd2cc0420ab0fe119` leaves RKE2
   active at PID `112223` with zero service restarts and the node's False MemoryPressure transition
   unchanged at `2026-08-27T23:59:22Z`. The full installed CLI run separately registers the
   pre-existing fake-Helm status drift as Sprint `5.38`; it fails before the Sprint `2.103`
   forwarding boundary and does not replace this sprint's independent validation.
3. ~~Deploy the exact correction and cross the pre-readiness routing boundary.~~ Done 2026-08-28:
   generation 68 publishes local/registry/containerd identities
   `sha256:442a27f857bfaabf00e7696e19d4a473ac94474039f8c2f9d8116683721639f1`,
   `sha256:214150bf68aa3ff4a63e87e051b6bd382f15f627fbb224dbefb3eb83c59dc013`, and
   `sha256:6e7fca1646ee6a12a6335b4e35ebe11e35a0108d674de34c4294717464fbfccf`.
   Fresh exact-image Pod `40e18d8a-9469-47e0-8049-f1676da61e2e` is Running with zero restarts.
   A read-only Deployment forward returns `/healthz` 200 and `/readyz` 503 while its EndpointSlice
   remains `ready: false`, proving the replacement coordinate without weakening readiness. The
   supported attempt still probes before kubectl binds its socket; that distinct timing defect is
   registered below.

### Closure Record

- The command-shape table, Recreate pin, complete local gate, and generation-68 two-sided live
  observation prove the owned pre-readiness routing correction.
- The next refusal occurs before the first HTTP request can reach that valid route and is separately
  registered as Sprint `2.104`.

## Sprint 2.104: Authority Backup Forwarding Waits for Its Socket Acknowledgement [✅ Done]

**Status**: Done and live-proven — generation 69 crosses the bounded socket acknowledgement and
reaches the later AWS-admin retained recovery observation.
**Implementation**: `src/Prodbox/ControlPlane/LocalClient.hs` and focused validation in
`test/unit/Main.hs`.
**Live-proof**: proven — generation 69 reaches AWS-admin genesis preparation through the exact
fresh-child Deployment forward.
**Deployment qualification**: proven on the owned startup-handshake boundary; Sprint `2.105` owns
the separately registered retained replay-window refusal.
**Independent Validation**: an injected acknowledgement reader and pure line classifier exhaust
IPv4/IPv6 success, EOF, timeout, unexpected output, and delayed success without Kubernetes; the
existing fresh-child retry and exact-coordinate cases remain independently green.
**Docs to update**: `documents/engineering/lifecycle_control_plane_architecture.md`,
`documents/engineering/helm_chart_platform_doctrine.md`, `DEVELOPMENT_PLAN/README.md`,
`DEVELOPMENT_PLAN/00-overview.md`, and `DEVELOPMENT_PLAN/system-components.md`.

### Objective

Distinguish subprocess creation from port-forward socket readiness. Each disposable Authority
Backup child must acknowledge the exact loopback mapping under a physical timeout before the
client sends `/healthz`; a child that exits, stalls, or announces another mapping is cleaned and
replaced without ever beginning the authenticated action.

### Live Counterexample (Generation 68, 2026-08-28)

The exact-image Adapter Pod is Running and a manually held Deployment forward emits
`Forwarding from 127.0.0.1:45124 -> 8600`, after which `/healthz` returns 200. The production loop
instead calls `startBackgroundProcess` and immediately sends HTTP. Connection refusal returns
before kubectl binds; bracket cleanup stops the child; only then does the 250 ms inter-attempt delay
run. Every one of 240 fresh children repeats that ordering and the command returns
`LocalAuthorityBackupLivenessFailed`. Stable counterexample
`FORWARD-STARTUP-HANDSHAKE-2026-08-28` is the exact-image live Pod, successful held-forward
acknowledgement/probe, and production create → refused probe → cleanup ordering.

### Deliverables

- Observe one exact IPv4 or IPv6 loopback `Forwarding from` acknowledgement from the child stdout
  under a compiled physical timeout before the first HTTP probe.
- Treat EOF, timeout, missing stdout, and any unexpected mapping as closed liveness failures; do
  not retain raw subprocess output or turn them into setup success.
- Keep acknowledgement observation inside the same bracket, preserve cleanup-before-inter-attempt
  delay, the 240-attempt outer bound, and exactly-once authenticated action semantics.
- Add injected and pure cases for both accepted loopback forms, foreign port/remote port/address,
  EOF, timeout, unexpected text, and success-before-probe event order.

### Validation

1. Focused cases exhaust the acknowledgement classifier and prove no probe occurs before success.
2. Sprint `2.102` retry and Sprint `2.103` coordinate/Recreate cases remain green.
3. Warning-clean all-target build, full unit/authority suites, documentation lint,
   `git diff --check`, and exact `prodbox dev check` pass.
4. A fresh exact-image supported reconcile crosses listener liveness, establishes the credential,
   commits/reads back config, and observes signed-store readiness. Any later refusal is registered
   separately before behavior changes.

### Remaining Work

1. ~~Implement the bounded acknowledgement observation and focused regressions.~~ Done 2026-08-28:
   each child stdout is observed under a one-second physical timeout; only exact IPv4/IPv6
   loopback mappings for the reserved local port and compiled remote port continue to HTTP. EOF,
   timeout, absent stdout, foreign address/port, and unexpected text return closed liveness
   failures without retaining output. The focused case passes 1/1, the combined Sprints
   `2.100`–`2.104` slice passes 7/7, targeted HLint reports `No hints`, and the warning-clean
   all-target build succeeds.
2. ~~Run the complete local gate.~~ Done 2026-08-28: all **4694** primary cases and the
   **27/33/29** authority suites pass; documentation lint, `git diff --check`, targeted HLint
   (`No hints`), the warning-clean all-target build, and exact canonical `prodbox dev check` exit
   0. Refreshed binary
   `sha256:0f68afa53a263b643cfe74072ca1a94b381bfcb5f378ad8bded0c6d0580030c9` leaves RKE2
   active at PID `239871` with zero restarts and the node's False MemoryPressure transition
   unchanged at `2026-08-27T23:59:22Z`.
3. ~~Deploy the exact correction and cross establishment, config CAS, and store readiness on the
   supported path.~~ Done on the sprint-owned boundary 2026-08-28: generation 69 publishes local
   image `sha256:b1f322bc1fa17defffbef2c383bdd8502f5dc3cd6d955a9de0678fdf6e749700`, registry
   digest `sha256:1775c828b2ddab55fa200a19d2bad16679e74f3847f5c111db8517dd860131d2`, and
   containerd OCI manifest
   `sha256:695c1a38ae6ee7b2798013c83bfa0b5a61706cf7a8105216c389846771bbf1a3`.
   Fresh exact-image Pod `0ad1841d-a126-451c-b22e-ca2db2ef55a5` is Running with zero restarts.
   The supported client crosses socket startup and liveness, prepares AWS-admin genesis, and
   reaches its recovery observation. That fifth retained authenticated request exposes the
   distinct replay-window refusal registered below before behavior changes.

### Closure Record

- The pure acknowledgement table, preserved retry/coordinate cases, complete local gate, and
  generation-69 crossing prove the create-before-bind race is closed.
- The next refusal is after HTTP startup and AWS-admin preparation; Sprint `2.105` owns its
  separately retained replay-capacity boundary.

## Sprint 2.105: Lifecycle Authority Replay Window Covers Bounded First Reconcile [✅ Done]

**Status**: Done and live-proven — generation 70 migrates the retained projection and crosses the
former fifth-request refusal into endpoint-owned AWS-admin preparation.
**Implementation**: `src/Prodbox/ControlPlane/RequestReplay.hs`,
`src/Prodbox/ControlPlane/Runtime.hs`, `src/Prodbox/ControlPlane/AwsAdminProvisionerClient.hs`, and
focused validation in `test/unit/Main.hs`.
**Deployment qualification**: proven on the owned replay-window and response-classification
boundaries; Sprint `2.106` owns the separately registered prepared-target diagnostic refusal before
the remaining first-reconcile graph resumes.
**Independent Validation**: pure request traces prove capacity four refuses the exact fifth request
and the compiled window admits the hard eight-member protocol's 56 Lifecycle Authority requests;
codec cases prove widening-only v2 migration and current v3 round trips without Kubernetes or
object storage; a client table proves non-endpoint HTTP refusal precedence without retaining a
body.
**Docs to update**: `documents/engineering/lifecycle_control_plane_architecture.md`,
`DEVELOPMENT_PLAN/README.md`, `DEVELOPMENT_PLAN/00-overview.md`, and
`DEVELOPMENT_PLAN/system-components.md`.

### Objective

Make durable replay capacity a bound of the protocol that consumes it. The complete hard-maximum
first-reconcile graph fits within one request-lifetime window while every accepted nonce, digest,
deadline, and response remains replayable. A retained capacity-four projection upgrades in place
through an explicit canonical widening migration; no cleanup, overwrite, or fresh-store shortcut
is allowed.

### Live Counterexample (Generation 69, 2026-08-28)

The generation-69 exact-image Adapter Pod crosses the new socket acknowledgement and `/healthz`.
Lifecycle Authority then accepts admission observe, begin-genesis control, confirmation observe,
and AWS-admin prepare. All four entries remain inside their five-minute deadline plus clock skew.
The coordinator's immediate recovery observation is request five, so the retained replay fold
returns `authenticated-replay-capacity-exhausted` with HTTP 503 before the endpoint handler runs.
The AWS-admin endpoint client attempts endpoint CBOR decoding first and renders the outer refusal
as `AwsAdminProvisionerClientResponseInvalid ControlPlaneRequestInvalid`. Stable counterexample
`LIFECYCLE-REPLAY-WINDOW-2026-08-28` is that exact accepted four-entry prefix, refused fifth
request, and masking client classification.

The hard first-reconcile plan contains at most eight members. Its maximum same-window Lifecycle
Authority request envelope is 56: three initial admission calls; five genesis provisioner calls;
five target/copy/confirmation calls; seven remaining members at one continuation observation plus
five provisioner calls each; and one final continuation observation. The projection's independent
encoded-byte ceiling remains authoritative if unrelated large replay responses consume it; entry
count does not weaken that byte bound.

### Deliverables

- Replace the four-entry Lifecycle Authority count with a finite compiled capacity no smaller than
  the 56-request hard-plan envelope; keep sibling-role capacities and the independent encoded-byte,
  per-response, clock-skew, and CAS-attempt bounds unchanged.
- Advance the replay codec and admit exactly a canonical prior-version projection whose response
  and skew limits equal the current limits and whose capacity is no greater than the target.
  Preserve every entry and project current limits in memory so the next successful CAS writes the
  current version. Refuse capacity shrink, other limit drift, corrupt/non-canonical bytes,
  over-capacity entries, and unknown versions.
- Classify a non-success outer HTTP status with a non-endpoint body before reporting endpoint codec
  failure. Preserve valid encoded endpoint refusal/unavailable responses and keep raw bodies out of
  every error.
- Add pure count/capacity, migration, current round-trip, and client-precedence regressions. Deploy
  the exact correction and register any later distinct refusal before changing it.

### Validation

1. A pure request sequence reproduces capacity-four exhaustion at request five and proves the
   compiled target admits all 56 hard-plan requests without compaction.
2. Codec tables accept canonical v2 capacity four → current widening while preserving entries;
   current codec round-trips; shrink, response/skew drift, corruption, non-canonical bytes,
   over-capacity entries, and unknown versions refuse.
3. AWS-admin response classification gives outer non-success status precedence only when endpoint
   decoding fails; encoded endpoint refusals remain their closed typed causes and a malformed 200
   remains a response-codec error.
4. Warning-clean all-target build, full unit/authority suites, documentation lint,
   `git diff --check`, and exact `prodbox dev check` pass.
5. A fresh exact-image supported reconcile migrates the retained projection without resetting it
   and crosses establishment, the remaining first-reconcile plan, config CAS/read-back, and signed
   Adapter store readiness. Any later refusal is registered separately before behavior changes.

### Remaining Work

1. ~~Implement the replay bound, widening-only retained codec migration, and outer-status client
   classification with focused regressions.~~ Done 2026-08-28: the runtime derives the 56-request
   envelope from the exported eight-member plan maximum and selects capacity 64 while preserving
   the 12 MiB encoded and 2 MiB per-response bounds. Codec v3 admits canonical v2 capacity four
   only toward equal or greater current capacity with identical other limits and preserves its
   non-empty entry; shrink, response/skew drift, unknown version, malformed, noncanonical, and
   current-version limit drift refuse. A malformed non-success outer response becomes the closed
   status while valid endpoint refused/unavailable CBOR retains its typed cause and malformed 200
   remains a codec error. The focused client case passes 1/1, the complete authenticated transport
   suite passes **31/31**, targeted HLint reports `No hints`, and the warning-clean all-target build
   succeeds.
2. ~~Run the complete local gate.~~ Done 2026-08-28: all **4695** primary cases and the
   **27/33/31** authority suites pass; documentation lint and `git diff --check` pass; pinned
   Fourmolu and HLint report no drift or hints; the warning-clean all-target build and exact
   canonical `prodbox dev check` exit 0. Refreshed binary
   `sha256:75fa463b397918b7268091f16b87296b8785e37b9871577c6f4b473b5b37c7c3` leaves RKE2
   active at PID `354288` with zero service restarts and the node's `False` MemoryPressure
   transition unchanged at `2026-08-27T23:59:22Z`.
3. ~~Deploy the exact correction and cross establishment, first-reconcile continuation, config CAS,
   and store readiness on the supported path.~~ Done on this sprint's owned boundary 2026-08-28:
   generation 70 publishes local image
   `sha256:1c604322c06f2d8e28f1a7987724bc1f82b1964b5350cca03cc90159779d9042`,
   registry digest
   `sha256:c00b86a5eec5a6f4b7b0ca7e815339be546324780ee91790e93c9eef6eee9969`, and
   containerd OCI manifest
   `sha256:20064008b7392e4bbbb61c16a622792a6a8b3647596b710e13f536c12ab6d340`.
   Exact Pod `21821a8a-7487-445c-bdc9-b25a053d5c92` is Running with zero restarts and binds the
   local image in both its rollout annotation and runtime image ID. The supported path crosses the
   former request-five exhaustion and returns the endpoint's typed
   `target-outbox-unavailable`; Sprint `2.106` owns that distinct diagnostic boundary before the
   remaining graph changes.

### Closure Record

- Capacity four reproduces the request-five refusal; capacity 64 admits all 56 requests in the
  compiled hard-plan envelope. Canonical v2 widening preserves live entries and v3 round-trips.
- The complete local gate and exact generation-70 crossing prove replay admission and client
  response precedence. The next endpoint-owned refusal is independently registered below.

## Sprint 2.106: Prepared-Target Failure Stage Is Observable [✅ Done]

**Status**: Done — generation 71 reports the exact closed
`first-reconcile-journal/plan-mismatch` cause without exposing private detail.
**Implementation**: `src/Prodbox/ControlPlane/AwsAdminPreparedTargetProduction.hs`,
`src/Prodbox/ControlPlane/AwsAdminProvisionerEndpoint.hs`, and focused validation in
`test/unit/CredentialProvisionerAwsAdminAuthority.hs` and `test/unit/Main.hs`.
**Deployment qualification**: proven — generation 71 runs the exact diagnostic image and exposes
the precise closed live cause while preserving the unavailable response class.
**Independent Validation**: a pure exhaustive renderer and injected endpoint table distinguish
every preparation stage/cause without Kubernetes, Vault, or object storage and prove distinct raw
details in one family render identically.
**Docs to update**: `documents/engineering/lifecycle_control_plane_architecture.md`,
`DEVELOPMENT_PLAN/README.md`, `DEVELOPMENT_PLAN/00-overview.md`, and
`DEVELOPMENT_PLAN/system-components.md`.

### Objective

Make the protected AWS-admin prepare refusal name the closed stage and cause that failed. The
diagnostic remains payload-free and changes no success/refusal decision, retry, admission,
first-reconcile journal, prepared-target outbox, permit, or credential behavior.

### Live Counterexample (Generation 70, 2026-08-28)

Generation 70 crosses retained replay migration and reaches
`prepareAndReadBackAwsAdminPreparedTarget`. That function can fail while reading Authority time,
reading or confirming admission, initializing/observing the first-reconcile journal, checking its
cursor, validating the deadline, canonicalizing the intent, constructing the prepared coordinate,
or observing/CAS-writing/reading back the prepared outbox. The endpoint discards every cause and
returns `target-outbox-unavailable`, falsely asserting that the failure belongs to the last stage.
Stable counterexample `PREPARED-TARGET-FAILURE-COLLAPSE-2026-08-28` is that exact typed response
after the former replay refusal is crossed.

### Deliverables

- Replace the preparation path's ordinary stringly error with a closed stage/cause ADT covering
  time, admission, first-reconcile journal, deadline, intent canonicalization, admission
  confirmation, coordinate construction, and outbox observation/CAS/read-back.
- Render one stable payload-free endpoint label per constructor. Preserve raw boundary detail only
  inside the private failure value where it is needed for classification; never serialize it.
- Preserve response status, retry behavior, effect order, and every state transition exactly. This
  sprint diagnoses only; it does not reinterpret missing, clear retained state, or retry mutation.
- Add exhaustive cause/renderer and endpoint-projection regressions, including equal public output
  for distinct private details within one cause.

### Validation

1. The closed cause enumeration and renderer are total and produce unique stable labels across
   distinct stages while same-family raw details remain indistinguishable publicly.
2. An injected endpoint maps every preparation failure to the same unavailable response class with
   its exact closed suffix; successful preparation remains byte-identical.
3. Warning-clean all-target build, full unit/authority suites, documentation lint,
   `git diff --check`, and exact `prodbox dev check` pass.
4. A fresh exact-image supported reconcile crosses replay migration and reports the precise
   prepared-target stage/cause. Register that distinct correction before changing behavior.

### Remaining Work

1. ~~Implement the closed preparation failure taxonomy and protected endpoint rendering with
   focused regressions.~~ Done 2026-08-28: a 20-constructor cause algebra covers every preparation
   stage, retains private detail only inside the internal error, and renders stable
   `prepared-target/<cause>` labels through the unchanged unavailable response. The exhaustive
   two-sided cause/label and private-detail noninterference cases pass **2/2**; targeted HLint
   reports `No hints`, and the warning-clean all-target build succeeds.
2. ~~Run the complete local gate.~~ Done 2026-08-28: all **4697** primary cases and the
   **27/33/31** authority suites pass; documentation lint and `git diff --check` pass; pinned
   Fourmolu and full HLint report no drift or hints; the warning-clean all-target build and exact
   canonical `prodbox dev check` exit 0. Refreshed binary
   `sha256:70db712a9005f8522eb24d2d64fdd4d3cbb69564b8b9c9000d8da5cf3bdcc5cf` leaves RKE2
   active at PID `474562` with zero service restarts and the node's `False` MemoryPressure
   transition unchanged at `2026-08-27T23:59:22Z`.
3. ~~Deploy the exact diagnostic and register the observed correction before behavior changes.~~
   Done 2026-08-28: generation 71 publishes local image
   `sha256:24202f861d42a84f080c915db801aa2c49edb8b27f5ad2b43d6d75bdc0432052`, registry digest
   `sha256:37ab581456e29a82b899fbc9f9c0b2e3d84238e3536315cf9e7277fe80a939e3`, and containerd OCI
   manifest `sha256:d0b0c4a2454b7100a8df1ea61201a5cf03e84ef6fae9635d63907d0fb6b39926`.
   Exact Pod `4a522e56-d48a-44ae-8781-e93db0a670dd` is Running with zero restarts and binds the
   local image in its rollout annotation and runtime image ID. The supported reconcile returns
   `prepared-target/first-reconcile-journal/plan-mismatch`, registering Sprint `2.107` below.

### Closure Record

- The 20-constructor cause algebra, exhaustive renderer/endpoint regressions, complete local gate,
  and generation-71 crossing prove this sprint's diagnostic-only surface.
- The diagnosed retained-plan retry mismatch is separate behavior work owned by Sprint `2.107`.

## Sprint 2.107: Retained First-Reconcile Plan Survives Caller-Deadline Retry [✅ Done]

**Status**: Done and live-proven — generation 72 adopts the retained canonical plan unchanged and
reports its exact expired deadline instead of a caller-deadline digest mismatch.
**Implementation**: `src/Prodbox/ControlPlane/AwsAdminPreparedTargetProduction.hs` and focused
validation in `test/unit/CredentialProvisionerAwsAdminAuthority.hs` and `test/unit/Main.hs`.
**Deployment qualification**: proven — generation 72 crosses retained journal-plan admission
without replacing or extending the journal deadline.
**Independent Validation**: a stateful in-memory Model-B adapter presents missing and retained
journal observations so initialization, replay adoption, drift refusal, and retained-deadline
behavior are proven without Kubernetes, Vault, or object storage.
**Docs to update**: `documents/engineering/lifecycle_control_plane_architecture.md`,
`documents/engineering/lifecycle_reconciliation_doctrine.md`, `DEVELOPMENT_PLAN/README.md`,
`DEVELOPMENT_PLAN/00-overview.md`, and `DEVELOPMENT_PLAN/system-components.md`.

### Objective

Make first-reconcile journal creation an absence-only decision and make every later retry consume
the exact canonical retained plan and its Authority-owned deadline. Never compare a retained
deadline-bound digest with a newly derived caller deadline, and never refresh an expired plan by
retrying.

### Live Counterexample (Generation 71, 2026-08-28)

The first supported attempt retains a journal whose plan digest covers its absolute deadline. The
next attempt derives a fresh deadline, calls `initializeFirstReconcileJournalStore` with the fresh
plan even though the coordinate is already present, then compares the observed digest with that
fresh plan. The topology is identical but the deadline-bound member and plan digests differ, so the
valid retained journal refuses as `prepared-target/first-reconcile-journal/plan-mismatch`. Stable
counterexample `FIRST-RECONCILE-DEADLINE-RETRY-MISMATCH-2026-08-28` is that exact generation-71
response.

### Deliverables

- Observe before initialization. Initialize the compiled plan from the admitted request deadline
  only when the journal is definitively missing, then read it back.
- When a journal is observed, validate its plan against the compiled action topology regenerated
  from the journal's own retained deadline and adopt it unchanged.
- Preserve fail-closed corrupt, unready, unobservable, noncanonical-plan, cursor, and deadline
  results. A retry cannot replace a journal, extend its deadline, clear receipts, or reset a cursor.
- Add two-sided stateful regressions: missing initializes once; a different caller deadline adopts
  the retained canonical journal without CAS; structural drift refuses; an expired retained
  deadline remains expired.

### Validation

1. A fresh missing coordinate initializes and reads back the compiled plan exactly once.
2. A retry with a different caller deadline returns the byte-equivalent retained journal and makes
   no write; a noncompiled retained topology returns the closed plan-mismatch cause.
3. Preparation uses the retained deadline, including the existing deadline-expired refusal, rather
   than the retry's deadline.
4. Warning-clean all-target build, full unit/authority suites, documentation lint,
   `git diff --check`, and exact `prodbox dev check` pass.
5. A fresh exact-image supported reconcile crosses the generation-71 journal-plan refusal. Any
   later distinct refusal is registered separately before behavior changes.

### Remaining Work

1. ~~Implement absence-only initialization and canonical retained-plan adoption with focused
   stateful regressions.~~ Done 2026-08-28: preparation now observes before mutation, performs one
   `ModelBInitialize` only after definitive absence, and validates any observed plan against the
   compiled topology regenerated from that plan's retained deadline. The stateful missing/retry and
   structural-drift cases pass **2/2**: first creation writes once, a different caller deadline
   returns the identical retained journal with zero additional writes, its original deadline is
   unchanged, and a noncompiled topology refuses without mutation. Targeted HLint reports
   `No hints`, and the warning-clean all-target build succeeds.
2. ~~Run the complete local gate.~~ Done 2026-08-28: all **4699** primary cases and the
   **27/33/31** authority suites pass; documentation lint and `git diff --check` pass; pinned
   Fourmolu and full HLint report no drift or hints; the warning-clean all-target build and exact
   canonical `prodbox dev check` exit 0. Refreshed binary
   `sha256:a2702e5c779e7849f4f46001ea537c874e76394d7d750fa751d7345ea6f013e8` leaves RKE2 active at
   PID `585596` with zero service restarts and the node's `False` MemoryPressure transition
   unchanged at `2026-08-27T23:59:22Z`.
3. ~~Deploy the exact correction and cross the retained journal-plan refusal on the supported
   path.~~ Done 2026-08-28: generation 72 publishes local image
   `sha256:f15bccd21d8b874b583cc8cf618bd85028d59db4b4986c967514b3d575c9a699`, registry digest
   `sha256:a228d0c8dca38bb0fb515833db1924ed66d20c486ed507f68c9154444ab17228`, and containerd OCI
   manifest `sha256:af744c7e9ee63d41f16c9284fc5c9cbcfae8f2edff6d63edb715a6db67e4a78a`.
   Exact Pod `3a8762ff-0242-4f1c-a58d-412770636f54` is Running with zero restarts and binds the
   local image in its rollout annotation and runtime image ID. The supported reconcile crosses the
   plan mismatch and returns `prepared-target/deadline-expired`; Sprint `2.108` owns that distinct
   expired-session recovery boundary.

### Closure Record

- The stateful missing/retry and drift refusals, complete local gate, and generation-72 crossing
  prove absence-only creation and byte-identical retained-plan adoption.
- The immutable plan remains valid; renewal of an expired active prompt/permit session is separate
  work registered below.

## Sprint 2.108: Expired Prepared First-Reconcile Session Renews Safely [✅ Done]

**Status**: Done — generation 73 crossed the generation-72
`prepared-target/deadline-expired` refusal and reached Credential Provisioner Job creation.
**Implementation**: `src/Prodbox/Lifecycle/CredentialProvisioner/AwsAdminAuthority.hs`,
`src/Prodbox/ControlPlane/AwsAdminPreparedTargetProduction.hs`,
`src/Prodbox/ControlPlane/AwsAdminProvisionerEndpoint.hs`,
`src/Prodbox/ControlPlane/AuthorityBackupReconcileProduction.hs`, and focused validation in
`test/unit/CredentialProvisionerAwsAdminAuthority.hs`.
**Deployment qualification**: complete — generation 73 renewed the exact expired `Prepared`
operation and advanced to the separately registered missing execution-substrate refusal.
**Independent Validation**: pure state transitions and stateful fake repositories/outboxes exhaust
eligible and ineligible renewal phases, exact immutable bindings, CAS loss/retry, effect order, and
active-deadline use without Kubernetes, Vault, object storage, or AWS.
**Docs to update**: `documents/engineering/lifecycle_control_plane_architecture.md`,
`documents/engineering/lifecycle_reconciliation_doctrine.md`, `DEVELOPMENT_PLAN/README.md`,
`DEVELOPMENT_PLAN/00-overview.md`, and `DEVELOPMENT_PLAN/system-components.md`.

### Objective

Separate the journal plan's immutable origin identity from the bounded deadline of each active
prompt/permit attempt, and renew only an expired operation that is durably `Prepared` but has never
been attested. Preserve the operation, request, generation, plan member, journal receipts, and
cursor exactly.

### Live Counterexample (Generation 72, 2026-08-28)

Generation 69 committed the deterministic genesis prepared outbox and Authority `Prepared` state,
then its next authenticated recovery observation exhausted the former replay window before any Job
creation or attestation. Generation 72 correctly adopts the retained journal and refuses its old
30-minute deadline as `prepared-target/deadline-expired`. The retained plan is not corrupt and must
not be cleared; the unfinished active session needs a proof-carrying renewal. Stable counterexample
`EXPIRED-PREPARED-FIRST-RECONCILE-2026-08-28` is that exact state and response.

### Deliverables

- Keep the retained plan digest/member/cursor as immutable ordering identity. Canonicalize each
  genesis or continuation attempt with its fresh caller deadline; the plan-origin deadline does not
  authorize a Job or permit.
- Admit renewal only when the exact operation state is `Prepared`, its old deadline is expired, the
  replacement deadline is future and greater, and operation/permit/request/generation/class/action,
  IAM program, Authority scope/endpoint, and plan binding are identical. Image and registered Agent
  rollout may advance.
- Because an expired prepared state cannot concurrently attest, CAS-replace and read back the exact
  old prepared outbox before CAS-replacing and reading back the Authority state. Exact response loss
  resumes; divergent, nonexpired, attested, authorized, completed, or unobservable state refuses.
- Use the fresh active deadline for every continuation compiler and permit validation while leaving
  journal bytes, receipts, and cursor untouched.

### Validation

1. The pure renewal table admits exactly expired `Prepared` plus an immutable-equivalent future
   replacement and refuses every phase, deadline relation, and immutable-field drift.
2. Stateful outbox/repository tests prove outbox-before-state ordering, exact read-back, lost-response
   recovery, and no mutation on ineligible state.
3. Existing exact replay remains byte-identical and all deadline/attestation/signature checks remain
   fail-closed against the active attempt deadline.
4. Warning-clean all-target build, full unit/authority suites, documentation lint,
   `git diff --check`, and exact `prodbox dev check` pass.
5. A fresh exact-image supported reconcile crosses `prepared-target/deadline-expired`. Any later
   distinct refusal is registered separately before behavior changes.

### Remaining Work

1. ~~Implement the prepared-only renewal transition, outbox/state CAS protocol, and active-deadline
   separation with focused regressions.~~ Done 2026-08-28: the Authority admits only an expired
   exact `Prepared` state whose immutable request, IAM, Authority, and nonempty plan binding match;
   vacant/attested, nonexpired, and drifted cases refuse. The production endpoint observes that
   phase before allowing replacement, the prepared-target layer CAS-replaces only the exact old
   outbox and reads back the new one, and the Authority state CAS follows with response-loss
   recovery. Continuation compilation now ignores the retained plan-origin deadline and uses the
   fresh active deadline. The focused renewal/ordering/continuation cases pass **3/3**, targeted
   HLint reports `No hints`, and the warning-clean all-target build succeeds.
2. ~~Run the complete local gate.~~ Done 2026-08-28: all **4701** primary cases and the
   **27/33/31** authority suites pass. Pinned Fourmolu, repository-wide HLint (`No hints`),
   documentation lint, `git diff --check`, the warning-clean all-target build, and the exact
   canonical `prodbox dev check` are green. Refreshed binary
   `sha256:d5697b61480a7028f9216b522f86e74e3bb0e3081f5cdac71186297fefc13272` leaves RKE2
   active at PID `696112` with zero service restarts and the node's `False` MemoryPressure
   transition unchanged at `2026-08-27T23:59:22Z`.
3. ~~Deploy the exact correction and cross the expired prepared session on the supported path.~~
   Done 2026-08-28: generation 73 publishes local image
   `sha256:496ff64450246a2633826b0f61628f0f9c5a7021ebe43b1baafc4ddb2d140b5b`, registry digest
   `sha256:fbb8689696eca6fb92f421c9195b3c3d9a627aab8413ccf1472b290ceef23063`, and containerd OCI
   manifest `sha256:1baa83e0458098914015355e3ffeff5291a78f5a19396ca924b619b6500fbf8c`.
   Exact Authority Backup Pod `2162fee1-c40f-47bd-be57-33c27d8aaed2` and Lifecycle Authority Pod
   `3b956dce-3550-4fed-9ae7-85924564c619` are Running with zero restarts and bind that local image
   in both rollout annotation and runtime image ID. The supported path crosses renewal and reaches
   Job creation, where Sprint `2.109` owns the distinct missing execution substrate.

### Closure Record

- Exact stateful local proof plus generation 73 prove renewal is restricted to the expired,
  unattested operation and preserves the retained plan/cursor while advancing its active deadline.
- The later Job-create refusal is not a renewal failure; it is registered below before any
  substrate behavior changes.

## Sprint 2.109: Credential Provisioner Execution Substrate Precedes Genesis [✅ Done]

**Status**: Done — the typed substrate passed the complete local gate and Generation 78 observed
all seven exact resources before creating the permit-bound Job on 2026-08-28.
**Implementation**: `src/Prodbox/CLI/Rke2.hs`, a pure Credential Provisioner substrate renderer,
the component/reconcile graph projection, and focused validation under `test/unit/`.
**Live-proof**: proven — Generation 78 crosses exact substrate read-back and creates the Job; Sprint
`2.110` owns the distinct Pod runtime-identity admission refusal.
**Deployment qualification**: pending — Sprint `2.110` owns the distinct runtime-identity
correction before the complete create-to-attestation composition can be exercised.
**Independent Validation**: pure manifest and plan-order tests prove the fixed namespace, both
schema-specific ServiceAccounts, default-deny/closed egress, least-privilege Job observation and
attach permissions, and substrate-before-establishment ordering without Kubernetes or AWS.
**Docs to update**: `documents/engineering/lifecycle_control_plane_architecture.md`,
`documents/engineering/lifecycle_reconciliation_doctrine.md`, `DEVELOPMENT_PLAN/README.md`,
`DEVELOPMENT_PLAN/00-overview.md`, and `DEVELOPMENT_PLAN/system-components.md`.

### Objective

Make the Credential Provisioner's non-secret Kubernetes execution substrate an explicit,
idempotent precondition of the first reconcile. The Lifecycle Authority may prepare a permit only
after the fixed namespace, schema-specific ServiceAccounts, isolation policy, and narrowly bound
controller permissions exist on the mandatory retained local control plane; a Job remains
permit-created and cleanup-owned, never a standing workload or an implicit side effect of another
chart. Selecting an AWS target does not duplicate or move this authority onto EKS.

### Live Counterexample (Generation 73, 2026-08-28)

The supported reconcile renews the exact expired `Prepared` AWS-admin operation, then returns
`AwsAdminCoordinatorCreateFailed "Job create failed and exact Job is absent"`. Authoritative
read-only observation proves namespace `credential-provisioner` is absent, therefore both its
ServiceAccount and every namespaced policy/permission are absent, and no Job event exists.
Stable counterexample `MISSING-CREDENTIAL-PROVISIONER-SUBSTRATE-2026-08-28` is that exact
pre-create state and response.

### Live Refinement (Generation 74, 2026-08-28)

Generation 74 publishes local image
`sha256:9bc22c53022bf28bfc4f0f030c80d7045b0977265bd149b5164c5a5402d1936d`, registry digest
`sha256:c8baf4ba31912e6362d251617af131c42005f1114dfd8b82fdff87158874415e`, and containerd OCI
manifest `sha256:dd313078eafe6d20c6fb8322424380bf95be65b9e21563a7056f5cbbb7d77980`. The supported
transition creates all seven objects and then refuses `CredentialProvisionerSubstrateDrifted`.
The exact diff is only `metadata.generation: 1` versus dry-run-predicted generation 2 on the two
NetworkPolicies; an independent read-only API projection proves every desired field current.
Stable refinement `NETWORKPOLICY-GENERATION-DIFF-2026-08-28` demonstrates that `kubectl diff` is
an apply prediction containing server-owned metadata, not the required exact current-state
observation. The observer therefore reads the seven exact kind/namespace/name keys and compares
every desired field while excluding fields the API server owns. Missing keys, changed desired
fields, duplicate keys, malformed output, authorization failure, and unavailable observation all
remain fail-closed.

### Live Refinement (Generations 75–78, 2026-08-28)

Generation 75 is non-proof because a transient node taint delayed Bootstrap Broker scheduling past
its fixed observation budget. Generation 76 is non-proof because importing the image crossed the
kubelet ephemeral-storage threshold and temporarily evicted the local registry. Read-only Docker
inventory identified 19 superseded untagged prodbox runtime images and about 52 GB of prior
prodbox Dockerfile build cache; deleting only those recoverable generated artifacts restored the
node from 40 GB to 89 GB free without touching retained application data or the tagged image.

Generation 77 then proved the API server canonically omits empty NetworkPolicy `spec.ingress`
arrays. The exact-keyed observer now treats only a desired empty array as equal to an omitted API
field; every nonempty or non-array omission remains drift. Generation 78 publishes local image
`sha256:c04e001578a2f508ae9de00ea7c41717f337663fe4d35ae29c09419ca4e2e2cb`, registry digest
`sha256:ac3f333284f9cd1c6a4bab2740dfa0faf9adf197fc59c2b58030b7bfa432b5f0`, and containerd OCI
manifest `sha256:19abd37a9344ffdac3601f154753b843c42a789b21728ccdf5c2fdf47f548c50`.
It observes all seven exact resources current and creates the permit-bound Job. The distinct
container-start refusal is registered in Sprint `2.110`; it does not falsify this sprint's
substrate crossing.

### Deliverables

- Add one typed reconcile component/step for the fixed Credential Provisioner substrate after
  unsealed Vault and the Target Secret Agent, and before Lifecycle Authority-backed genesis on the
  mandatory local control plane that both target selections consume.
- Render and reconcile the namespace, the distinct AWS-admin and external-material
  ServiceAccounts, schema-selecting default-deny NetworkPolicies with only compiled DNS, Vault,
  authenticated control-plane/Target-Agent, and required provider HTTPS egress, plus the narrow
  controller Job/Pod/attach/read-back permissions. No Secret/ConfigMap read and no standing Pod.
- Observe the exact substrate after apply and fail closed on missing, drifted, unauthorized, or
  unobservable resources. Job creation does not infer readiness from apply exit.
- Preserve permit-created Job identity, attestation, stdin-only material delivery, deletion,
  stable-absence read-back, and the Sprint `2.108` renewed Authority/outbox state unchanged.

### Validation

1. Pure manifest tests pin every object, namespace, subject, verb, selector, port, and the absence
   of Secret/ConfigMap access or a standing workload.
2. The compiled retained-local plan places substrate reconciliation after its prerequisites and
   before any Credential Provisioner Job creation; the AWS target plan cannot duplicate it or move
   authority onto EKS, and no other chart implicitly owns it.
3. Stateful apply/read-back tests prove exact idempotence, response-loss recovery, and refusal on
   absent/drifted observations.
4. Warning-clean all-target build, full unit/authority suites, documentation lint,
   `git diff --check`, and exact `prodbox dev check` pass.
5. A fresh exact-image supported reconcile observes the substrate and creates the permit-bound Job.
   Attestation or any later distinct refusal is registered separately before behavior changes.

### Remaining Work

1. ~~Implement the typed substrate renderer, ordered reconcile/read-back, and focused
   regressions.~~ Done 2026-08-28: one seven-object manifest owns the namespace, two
   schema-specific non-automount ServiceAccounts, narrow controller Role/RoleBinding, and two
   schema-selected default-deny NetworkPolicies. The retained-local plan applies it after
   Lifecycle Authority handoff and before Authority Backup establishment, then accepts only a
   fresh exact-keyed `kubectl get -f -` projection; lost apply response plus exact observation
   recovers. Generation 74's two NetworkPolicy generation-only false diffs are pinned as
   server-owned metadata, while missing objects remain drift. Both Job interpreters share one
   caller-impersonation projection. Focused manifest/read-back/identity cases pass **3/3**, the
   graph/order/golden slice passes **5/5**, and targeted HLint reports `No hints`.
2. ~~Run the complete local gate.~~ Done 2026-08-28: all **4704** primary cases and the
   **27/33/31** authority suites pass. Pinned Fourmolu, repository-wide HLint (`No hints`),
   documentation lint, `git diff --check`, the warning-clean all-target build, and exact canonical
   `prodbox dev check` are green. Refreshed binary
   `sha256:2a38e34d66bf903c10ec3410403e3b019473c28efa0540e75b4889f6b64269ec` leaves RKE2
   active at PID `971174` with zero service restarts and the node's `False` MemoryPressure
   transition unchanged at `2026-08-27T23:59:22Z`.
3. ~~Deploy the exact correction and cross Job creation on the supported path.~~ Done 2026-08-28:
   after two explicitly non-proof resource-pressure attempts, Generation 78 carries the exact
   local/registry/containerd identities above, observes all seven objects current, and creates the
   permit-bound Job. Kubernetes' subsequent non-root identity refusal is registered below before
   its behavior changes.

### Closure Record

- Exact-keyed local tests and Generation 78 prove that Job creation is ordered after positive
  read-back of the complete non-secret retained-local substrate.
- Server-owned generation and omitted desired empty arrays cannot cause false drift, while missing
  keys and omitted nonempty desired fields still refuse.
- The later Pod admission failure is not an execution-substrate failure; Sprint `2.110` owns it.

## Sprint 2.110: Explicit Non-Root Credential Provisioner Runtime Identity [✅ Done]

**Status**: Done — the shared identity projection passed the complete local gate and Generation 79
was accepted and scheduled without the former non-root admission event on 2026-08-28.
**Implementation**: `src/Prodbox/Lifecycle/CredentialProvisioner/RuntimeSecurity.hs`,
`src/Prodbox/Lifecycle/CredentialProvisioner/AwsAdminKubernetes.hs`,
`src/Prodbox/Lifecycle/CredentialProvisioner/KubernetesJob.hs`, the workload-shape chart reference,
and focused validation under `test/unit/`.
**Live-proof**: pending — Generation 79 crossed the former non-root refusal but Sprint `2.111`'s
distinct immediate-observation race deleted the Pending Pod before kubelet pulled it.
**Deployment qualification**: pending — Sprint `2.111` owns bounded Pod convergence before the
complete create-to-attestation composition can be exercised.
**Independent Validation**: pure render assertions over both native ingress schemas prove the same
nonzero numeric UID/GID/fsGroup, `runAsNonRoot`, and seccomp projection without Kubernetes, AWS, or
image-metadata inference.
**Docs to update**: `documents/engineering/lifecycle_control_plane_architecture.md`,
`documents/engineering/lifecycle_reconciliation_doctrine.md`, `DEVELOPMENT_PLAN/README.md`,
`DEVELOPMENT_PLAN/00-overview.md`, and `DEVELOPMENT_PLAN/system-components.md`.

### Objective

Make the one-shot Credential Provisioner runtime identity explicit in every native Job manifest.
The Pod runs under one shared nonzero numeric UID/GID and fsGroup, so Kubernetes admission and
writable tmpfs ownership do not depend on the union image's default user. The role-neutral image
default and every other workload remain unchanged.

### Live Counterexample (Generation 78, 2026-08-28)

The supported reconcile observes the complete Sprint `2.109` substrate, creates Job
`credential-provisioner-genesis-cf14d8a4732a3a42e507de05`, schedules its Pod, and pulls the exact
Generation-78 image. Kubelet then reports `container has runAsNonRoot and image will run as root`:
the Pod declares `runAsNonRoot: true`, the image has no non-root `USER`, and neither native
renderer supplies `runAsUser`. The coordinator removes the failed Job and Pod. Stable
counterexample `CREDENTIAL-PROVISIONER-NONROOT-IDENTITY-2026-08-28` is that exact admission event.

### Deliverables

- Define one shared pure Pod security-context projection with explicit nonzero `runAsUser`,
  `runAsGroup`, and `fsGroup`, plus `runAsNonRoot` and `RuntimeDefault` seccomp.
- Consume it from both the AWS-admin and external-material native Job renderers; keep container
  capability drop, privilege-escalation refusal, read-only root filesystem, and identity-token
  projection unchanged.
- Keep the chart workload-shape reference structurally aligned without making Helm the Job owner.
- Add two-sided render regressions that fail on root identity, renderer drift, missing fsGroup, or
  a reversion to image-user inference.

### Validation

1. Both native renderers carry the exact shared numeric identity and all existing hardening fields.
2. The workload-shape reference carries the same identity; no other union-image workload changes.
3. Focused tests, warning-clean all-target build, full unit/authority suites, documentation lint,
   `git diff --check`, and exact `prodbox dev check` pass.
4. A fresh exact-image supported reconcile reaches a Running, attested permit-bound AWS-admin Pod.
   Any later distinct refusal is registered separately before behavior changes.

### Remaining Work

None on Sprint `2.110`'s code-owned surface. The shared `65532` UID/GID/fsGroup projection is used
by both native renderers, the chart reference is aligned, and both focused exact-projection cases
pass. All **4705** primary cases and the **27/33/31** authority suites pass; repository-wide HLint
reports `No hints`, the warning-clean all-target build and canonical `prodbox dev check` are green,
and refreshed binary
`sha256:cb8e354edb805a1ea2f8010b0da1d29c8020998976712b82b59f58b2afbe8ede`
drives the exact Generation-79 identities below. The non-blocking live proof continues through the
separately registered Sprint `2.111` observation race.

### Live Crossing and Next Counterexample (Generation 79, 2026-08-28)

Generation 79 publishes local image
`sha256:c05ac94563e137837be7ac26dfee4ae849aaac40b23324145d4532be1e75190d`, registry digest
`sha256:f226bbe01f6f8ac7b9161ef0aa4aac5cccfbf0a002c8f1886aa0a5b12c6782dd`, and containerd OCI
manifest `sha256:422c3dc6dcbae03e2aef1d64327bbe1bdcd64d6c4cc1c2a0d84b0bac07db5147`.
Kubernetes accepts and schedules Pod
`credential-provisioner-genesis-cf14d8a4732a3a42e507de05-wscfj`; unlike Generation 78, it emits
no `runAsNonRoot` refusal. The coordinator observes in that same second, sees the legitimate
Pending phase, reports the broad identity/runtime drift arm, and deletes the Job/Pod before kubelet
pulls the image. That later observation race is Sprint `2.111`, not a runtime-identity failure.

## Sprint 2.111: Bounded Exact Pod Convergence Before Attestation [✅ Done]

**Status**: Done — the bounded observer passes the complete local gate and Generation 80 waits
through scheduling, image pull, and container start before reaching the later exact runtime-image
comparison.
**Implementation**: `src/Prodbox/Lifecycle/CredentialProvisioner/AwsAdminKubernetes.hs` and focused
validation in `test/unit/CredentialProvisionerAwsAdminAuthority.hs`.
**Live-proof**: pending — Generation 80 crosses the immediate-Pending race; Sprint `2.112` owns the
distinct pulled-manifest identity mismatch before Authority attestation.
**Deployment qualification**: pending — Sprint `2.112` owns the later immutable runtime-image
identity correction and complete create-to-attestation crossing.
**Independent Validation**: an injected observation/delay table proves the exact transitional
states retry within a finite budget while drift, deletion, terminal phases, and observation failure
remain immediate refusals, without Kubernetes or AWS.
**Docs to update**: `documents/engineering/lifecycle_control_plane_architecture.md`,
`documents/engineering/lifecycle_reconciliation_doctrine.md`, `DEVELOPMENT_PLAN/README.md`,
`DEVELOPMENT_PLAN/00-overview.md`, and `DEVELOPMENT_PLAN/system-components.md`.

### Objective

Let a newly created exact Credential Provisioner Pod converge through Kubernetes' normal
absent-status/Pending/not-yet-ready states before attestation. The bounded observer retains the
same Job UID, owner reference, Pod UID, ServiceAccount UID, annotations, image specification, and
runtime digest throughout; it never retries identity drift, deletion, a terminal phase, an API
failure, or budget exhaustion.

### Live Counterexample (Generation 79, 2026-08-28)

At `2026-08-28T21:10:08Z`, Job
`credential-provisioner-genesis-cf14d8a4732a3a42e507de05` creates and schedules Pod
`credential-provisioner-genesis-cf14d8a4732a3a42e507de05-wscfj` with UID
`367e8156-84b5-4435-bb17-33694865433a`. No kubelet pull/start event exists because the
coordinator's immediately following `kubectl get` sees phase Pending, returns
`AwsAdminKubernetesObservationFailed "Pod identity, ownership, or runtime phase drifted"`, and
cleanup removes the exact Job/Pod. Stable counterexample
`IMMEDIATE-POD-ATTESTATION-2026-08-28` is that create→schedule→immediate-read→delete trace.

### Deliverables

- Split exact immutable identity validation from runtime convergence classification.
- Retry only an exact owned Pod whose phase/status is legitimately transitional, using a finite
  attempt count and fixed delay beneath the active permit deadline.
- Return immediately on exact ready attestation input, authoritative absence, identity/image/
  ServiceAccount drift, deletion, terminal phase, API failure, or malformed observation.
- Preserve exception-safe exact UID cleanup and the existing attach/receipt/Authority protocol.

### Validation

1. A Pending→not-ready Running→exact-ready table consumes the expected attempts/delays and returns
   the original observation.
2. Identity drift, terminal phase, observation error, and absence never enter the retry loop;
   perpetual transitional state exhausts at the exact bound with a stable refusal.
3. Full unit/authority suites, repository-wide HLint, warning-clean all-target build,
   documentation/diff checks, and canonical `prodbox dev check` pass.
4. A fresh exact-image supported reconcile reaches Authority attestation. Any later distinct
   refusal is registered separately before behavior changes.

### Remaining Work

None on Sprint `2.111`'s code-owned surface. The injected state table proves exact transition,
immediate-refusal, absence, and exhaustion behavior; all **4706** primary cases and the
**27/33/31** authority suites pass, repository HLint reports `No hints`, the warning-clean build
and canonical `prodbox dev check` are green, and refreshed binary
`sha256:5ddd5b034c0b67a6d3492c6100b900b19b3b641545e2ead9ac092c8cee112a2f` drives the
Generation-80 crossing below.

### Live Crossing and Next Counterexample (Generation 80, 2026-08-28)

Generation 80 publishes local image
`sha256:8dbaf4e15fed6a46f2cc0285f8519bb113821fe98ac4eb43246c385d79e68025`, registry manifest
`sha256:0d779c8ec9bf1d6e1bb18ca425e6d03ce8a09c85ecaa75bfce95313834fbf54c`, and containerd OCI
manifest `sha256:27f27e7b41c87e6e563e323883b1c435fee462e16e592170873773d8f93e5426`.
Job `credential-provisioner-genesis-cf14d8a4732a3a42e507de05` creates and schedules Pod
`credential-provisioner-genesis-cf14d8a4732a3a42e507de05-q9kwx`; kubelet pulls the exact tag,
creates the container, and starts it. The coordinator therefore crossed the former immediate
Pending refusal. It then reports `worker container runtime identity drifted`: the permit digest is
currently the manifest's config digest, while an `Always` pull is attested by its pulled manifest
identity. Stable counterexample `CREDENTIAL-PROVISIONER-PULLED-MANIFEST-IDENTITY-2026-08-28`
belongs to Sprint `2.112`.

## Sprint 2.112: Pulled-Manifest Attestation Identity for Credential Provisioner Jobs ✅

**Status**: Done — Generation 82 proves the independently observed registry manifest is the exact
permit/runtime attestation identity and crosses the former drift refusal.
**Implementation**: `src/Prodbox/Lib/ChartPlatform.hs`,
`src/Prodbox/Lifecycle/CredentialProvisioner/AwsAdminKubernetes.hs`,
`src/Prodbox/Lifecycle/CredentialProvisioner/KubernetesJob.hs`, and focused validation under
`test/unit/`.
**Deployment qualification**: pending — deploy the exact manifest-attested Jobs and prove the
AWS-admin create-to-attestation composition reaches its terminal Authority result.
**Live-proof**: proven — Generation 82 reaches attach after exact registry-manifest attestation.
**Independent Validation**: injected image-inspection outputs and Pod status documents prove one
exact manifest digest across resolution, immutable rendering, and all accepted Kubernetes imageID
forms without Kubernetes, a registry, or AWS.
**Docs to update**: `documents/engineering/lifecycle_control_plane_architecture.md`,
`documents/engineering/lifecycle_reconciliation_doctrine.md`, `DEVELOPMENT_PLAN/README.md`,
`DEVELOPMENT_PLAN/00-overview.md`, and `DEVELOPMENT_PLAN/system-components.md`.

### Objective

Use one independently observed registry-manifest digest as the Credential Provisioner attestation
identity on its `Always`-pull path. The Authority permit signs that digest and runtime attestation
extracts it from Kubernetes' exact imageID representation. The validated pullable tag remains the
Job's addressing hint, never evidence; a config digest, a digest assembled into a pull reference,
or an independently inferred identity cannot satisfy the join.

### Live Counterexample (Generation 80, 2026-08-28)

The supported reconcile waits through legitimate Pod convergence and observes kubelet pull and
start for `credential-provisioner-genesis-cf14d8a4732a3a42e507de05-q9kwx`. The subsequent
`worker container runtime identity drifted` refusal exposes two different identity kinds: image
resolution supplies the registry manifest's `config.digest`, while `imagePullPolicy: Always`
causes Kubernetes to identify the pulled manifest. Stable counterexample
`CREDENTIAL-PROVISIONER-PULLED-MANIFEST-IDENTITY-2026-08-28` is that exact post-start refusal.

An unchanged-operator Generation-81 reproduction resolves the representation exactly. Local config
identity `sha256:a5cd787921fa0d119f863f2a4cfd81d44927258a819ac98bc6a971fb4f37983b`, registry manifest
`sha256:bf20d2979abf8489d4b8363a48d0672cf482713826cadaa2c4149fac531230ff`, and containerd OCI
manifest `sha256:75b52fa4111336b085fa072b61b525d411968248a8d54c81ebc59ddd14559c48` are different.
Read-only 250-millisecond Pod observation captures
`credential-provisioner-genesis-cf14d8a4732a3a42e507de05-jrhrn` UID
`b031604e-c300-43f2-936f-fe77810174e0` at `2026-08-28T22:34:21Z` with the mutable tag in
`spec.containers[].image` and exact runtime identity
`127.0.0.1:30080/prodbox/prodbox-runtime@sha256:bf20d2979abf8489d4b8363a48d0672cf482713826cadaa2c4149fac531230ff`.
This `Always`-pull path therefore differs from the locally present `IfNotPresent` config-identity
path Sprint `2.51` measured; the manifest is observed directly rather than reverse-resolved from a
config digest.

### Deliverables

- Resolve and validate the matching repository manifest digest as a distinct typed image identity;
  do not reuse a config digest as a manifest digest.
- Keep both native Credential Provisioner Jobs on their validated pullable reference and preserve
  the Sprint-`2.51` guard that forbids assembling a runtime digest into a pull reference.
- Parse the bounded Kubernetes imageID forms that preserve the exact `sha256:` manifest digest,
  while rejecting malformed, config-only, foreign, or ambiguous values.
- Keep bounded convergence, runtime hardening, cleanup, attach, receipt, and Authority protocols
  unchanged; add two-sided regressions for AWS-admin and external-material Jobs.

### Validation

1. Image resolution distinguishes config and registry-manifest digests and selects only the
   repository's exact manifest digest.
2. Both native Job manifests preserve the validated pullable reference, and matching plain,
   URI-qualified, and repository-qualified Kubernetes imageID forms attest the permit digest.
3. Config-digest substitution, digest-to-reference assembly, malformed identity, and foreign digest
   refuse in focused tests.
4. Full unit/authority suites, repository-wide HLint, warning-clean all-target build,
   documentation/diff checks, and canonical `prodbox dev check` pass.
5. A fresh exact-image supported reconcile reaches Authority attestation. Any later distinct
   refusal is registered separately before behavior changes.

### Closure Evidence (Generation 82, 2026-08-28)

Focused AWS-admin and external-material suites pass **24/24** and **14/14**, the pure
repository-manifest selector passes **1/1**, all **4708** primary cases and the **27/33/31**
authority suites pass, and canonical `prodbox dev check` is green. Refreshed binary
`sha256:e6edff98d4306c694ae551ef9986731dd42c17189787c2382ee16a536e732bf2`
publishes local image
`sha256:042cc7bf2b84f3ebec4b0c81bddcc827e1cf5ee864865fdae5ed4f94d0a02a66`, registry manifest
`sha256:0110733a42e268f6361b399401c3e7583d4404d3cf9dd2bff870aed14480cdb6`, and containerd OCI
manifest `sha256:8e3a0199fd14353cada3151af0829bdc176f77a67236bc5fde9d6232d398cd1e`.
The exact permit carries that registry manifest and Pod UID
`3d3b05d2-9742-4b1f-a458-85eefbace0be` reports runtime imageID
`127.0.0.1:30080/prodbox/prodbox-runtime@sha256:0110733a42e268f6361b399401c3e7583d4404d3cf9dd2bff870aed14480cdb6`.
The observer accepts the join and advances to attach; the former identity-drift refusal does not
recur. The distinct missing-option failure remains owned by Sprint `2.113`.

## Sprint 2.113: Complete Native AWS-Admin Worker Arguments ✅

**Status**: Done — the native renderer derives and supplies the exact Target Worker repository,
and its complete rendered argv passes the production closed parser.
**Implementation**: `src/Prodbox/Lifecycle/CredentialProvisioner/AwsAdminKubernetes.hs` and focused
validation in `test/unit/CredentialProvisionerAwsAdminAuthority.hs`.
**Deployment qualification**: pending — first deploy after Sprint `2.112` crosses runtime
attestation must prove the native worker accepts its complete closed option set and reaches attach.
**Live-proof**: pending — Generation 83 stops at the separately registered pre-Job durable-state
counterexample owned by Sprint `2.114`.
**Independent Validation**: exact rendered argv is compared with the closed AWS-admin CLI parser's
required fields and the chart workload-shape reference without Kubernetes, a registry, or AWS.
**Docs to update**: `documents/engineering/lifecycle_control_plane_architecture.md`,
`documents/engineering/lifecycle_reconciliation_doctrine.md`, `DEVELOPMENT_PLAN/README.md`, and
`DEVELOPMENT_PLAN/00-overview.md`.

### Objective

Make the native permit-created AWS-admin Job pass the complete closed worker option set. The exact
Target-worker image repository already required by `AwsAdminWorkerOptions` is projected from the
same validated runtime image input into the native argv; the chart reference and native renderer
cannot silently disagree about parser-required options.

### Live Counterexample (Generation 81, 2026-08-28)

Read-only CRI history for container
`containerd://0d950851f45d36e1aaaba1dbce90974cd25a545a90ccbc6cbf0044534e71d4eb`
shows the one-shot process exits `1` before attach with the redacted parser diagnostic
`Missing: --target-worker-image-repository REPOSITORY`. The chart reference already renders that
option and a structural unit case requires it; the native AWS-admin renderer's `workerArguments`
does not. Stable counterexample `AWS-ADMIN-NATIVE-JOB-ARGV-2026-08-28` is that exact drift.

### Deliverables

- Project the validated Target-worker image repository into native AWS-admin worker argv.
- Keep the permit-bound execution image identity distinct from the Target worker repository the
  AWS-admin worker needs for its later closed materialization operation.
- Add an exact parser/render regression that fails when any required AWS-admin option is absent,
  duplicated, reordered incorrectly, or substituted.
- Preserve all Pod security, convergence, attestation, attach, cleanup, and Authority behavior.

### Validation

1. The native rendered argv is accepted by the same closed parser and carries the exact repository.
2. Missing or substituted repository input refuses before Job creation.
3. Focused tests, full local gate, and canonical `prodbox dev check` pass.
4. A fresh supported reconcile crosses option parsing and reaches the next exact lifecycle result;
   any later distinct refusal is registered separately before behavior changes.

### Closure Evidence (2026-08-28)

The focused AWS-admin suite passes **25/25**. The regression compares the entire rendered argument
vector, supplies it to the production CLI parser, proves the normalized untagged repository appears
exactly once, and refuses empty or digested execution-image input before rendering. All **4709**
primary cases and the **27/33/31** authority suites pass; canonical `prodbox dev check` is green.
Generation 83 uses refreshed binary
`sha256:43b36e4e77d9f3dbde641b3625aac7d29de37402ca2cf601874716c025e98988`
but stops before Job creation at the distinct durable-state counterexample registered as Sprint
`2.114`; no remaining code work belongs to the argv renderer.

## Sprint 2.114: Recover an Expired Prepared-Target Outbox One Step Ahead ✅

**Status**: Done (2026-08-28) on its code-owned persistence/recovery surface. Generation 86 proves
the retained live object is not this crash shape; that falsification registers the distinct
non-Prepared Authority-state recovery as Sprint `2.115` rather than broadening this classifier.
**Implementation**: `src/Prodbox/ControlPlane/AwsAdminPreparedTargetProduction.hs`,
`src/Prodbox/ControlPlane/AwsAdminProvisionerEndpoint.hs`, and focused validation in
`test/unit/CredentialProvisionerAwsAdminAuthority.hs`; the versioned envelope is owned by
`src/Prodbox/Lifecycle/CredentialProvisioner/PreparedTargetOutbox.hs` and both Authority/Target
readers consume it.
**Live-proof**: pending — no live run has yet injected the exact prepared-state/outbox-ahead crash
shape; the Model-B interruption proof is the code-local closure evidence.
**Deployment qualification**: pending — a fresh supported reconcile must recover the retained
expired outbox-ahead shape before this persistence-protocol change is deployment-qualified.
**Independent Validation**: an injected Model-B adapter exercises interruption after outbox replace
but before Authority-state CAS, then proves a later fresh renewal may replace only the expired
binding-equivalent intermediate without Kubernetes, Vault, a registry, or AWS.
**Docs to update**: `documents/engineering/lifecycle_control_plane_architecture.md`,
`documents/engineering/lifecycle_reconciliation_doctrine.md`, `DEVELOPMENT_PLAN/README.md`, and
`DEVELOPMENT_PLAN/00-overview.md`.

### Objective

Close the persist-before-state crash window without weakening exact prepared-target ownership.
When Authority retains an expired prepared predecessor and the outbox contains a separately expired
successor with the same owner, fence, target, generation, request digest, and plan binding, the next
renewal may CAS-replace that intermediate with its fresh desired successor before the existing
Authority renewal CAS. The legacy observation-only envelope is admitted once under its authenticated
exclusive-writer provenance; every replacement uses a versioned complete-intent envelope whose
receipt recomputes exactly from its deadline, selected Agent, image, and canonical intent. Active,
non-forward, malformed, unobservable, canonical receipt-invalid, or binding-drifted outboxes remain
exact refusals.

### Live Counterexample (Generation 83, 2026-08-28)

Refreshed binary `sha256:43b36e4e77d9f3dbde641b3625aac7d29de37402ca2cf601874716c025e98988`
publishes local image
`sha256:4a78e27ae25d5e3741c739ffec5078c5d1a508a63953bb16111a97ba1556cac6`, registry manifest
`sha256:aaf3db9cc9f3c30917c2fa521379a6a8cfe4d748e20fb7fa1834f7433a75fbe7`, and containerd OCI
manifest `sha256:3a666eb579a2410434825fb8c1223e0659b53adbafcaeee4403526d041f4f410`.
Before a new Job is created, prepare returns
`AwsAdminProvisionerClientUnavailable "prepared-target/outbox/divergent"`. Publication is ordered
before the Authority-state CAS; exact replay handles the same desired successor, but the retained
expired intermediate cannot be recognized when a later run legitimately advances deadline, image,
and selected Agent. Stable counterexample `PREPARED-TARGET-OUTBOX-AHEAD-2026-08-28` is this
persisted one-step-ahead state.

Generation 84 uses locally validated binary
`sha256:d6d013a860eb026f3319780a7d866a8227aaa006b4a92dd6845873501f35acc9`, local image
`sha256:7aba38f7a60e2f07682faee3e343952294f9a02e4772ce84549548cf875b2acf`, registry manifest
`sha256:ea806783a05f70b6b01398844ab18087bff244c549ebef66d194adb82a09d89e`, and containerd OCI
manifest `sha256:fcc3ce83f0324c80e04d6d9eef207b10d59bd5f3b1da3ab6e17c927d0fa07477`.
It reproduces the same protected refusal. The first classifier incorrectly required the successor
receipt digest to equal its predecessor even though that digest deliberately binds the advancing
deadline and selected Agent; genesis also binds its deadline-derived permit kind. The retained
counterexample therefore narrows recovery to an independently recomputed successor receipt rather
than licensing unvalidated receipt drift.

The focused correction then proves a second serialization fact: the receipt also binds the
execution image, which may advance on every supported build, but the version-1 outbox stores only
the prepared observation and not that image or complete intent. The already-retained Generation-83
receipt therefore cannot be recomputed from either its older Authority predecessor or its newer
desired successor. Recovery is a bounded schema migration: accept the authenticated legacy
observation only under the strict immutable/deadline predicate, immediately CAS-replace it with a
versioned complete-intent envelope, and require exact receipt rederivation for every new envelope.

### Deliverables

- Carry the Authority observation time with the retained renewal intent into prepared-target
  publication instead of discarding it at the endpoint boundary.
- Recognize only an outbox whose immutable target/plan ownership equals the retained predecessor,
  whose deadline moved strictly forward and whose own deadline is already expired. Limit the
  observation-only exception to the legacy authenticated codec.
- Persist the complete canonical intent in the replacement codec and reject it unless its prepared
  receipt is exactly rederived from that intent's deadline, selected Agent, image, and bindings.
- CAS-replace that exact intermediate with the fresh desired prepared target, then retain the
  existing outbox-read-back-before-Authority-state-CAS order and response-loss recovery.
- Add two-sided crash-window and codec-migration tests covering exact legacy/canonical recovery plus
  active, backward-deadline, owner, fence, target, generation, request, canonical invalid-receipt,
  and plan-binding drift refusals.

### Validation

1. The interrupted outbox-ahead fixture recovers to the fresh successor and then commits the
   Authority renewal under the retained predecessor.
2. Active, equal/backward-deadline, and every immutable-binding drift stays `outbox/divergent`
   without an outbox or Authority-state write.
3. Focused tests, all local suites, documentation/diff checks, and canonical `prodbox dev check`
   pass.
4. A fresh supported reconcile crosses the retained Generation-83 state and reaches the corrected
   native worker; any later distinct refusal is registered separately before behavior changes.

### Remaining Work

None on this sprint's code-owned surface. Its exact live fault injection remains the non-blocking
`Live-proof: pending` axis above. Sprint `2.115` owns the different retained non-Prepared state.

### Local Validation (2026-08-28)

The focused AWS-admin authority suite passes **27/27**. Its two Sprint-2.114 cases cover the
legacy/current codec boundary, invalid canonical receipt, all retained binding/deadline refusals,
and an injected Model-B interruption that observes `outbox-cas` before `state-cas`, then reads back
the complete desired intent. All **4711** primary cases and the **27/33/31** authority suites pass.
Canonical `prodbox dev check` reports `No hints` and completes its warning-clean all-target build.
Refreshed binary
`sha256:9beb05dabff45ceefb25639ad1e0af98840ac9d1d77c9688907fcbc83db07fff` is the Generation-85
qualification input. Generation 85 publishes local image
`sha256:f9d8a5f2a8e1f0456f04782facce8de3211c10f57638119afb2709bc09c6913e`, independently
observes registry manifest
`sha256:9b45646b30c45191191350e86f14a2d27b25fa06068c53d961aecbf74849259c`, and imports
containerd OCI manifest
`sha256:9fcd3a25510161c1854fb7d93b4572cc8956bc1ff0d4f2b872e29442d5d65eb2` before reproducing
`prepared-target/outbox/divergent`. MinIO's read-only object inventory proves the legacy outbox was
not rewritten, so refusal precedes the migration CAS and at least one strict immutable/deadline
predicate differs from the inferred crash shape. Stable counterexample
`LEGACY-OUTBOX-PREDICATE-2026-08-28` requires a payload-free private discriminator before the
predicate can be corrected; deployment remains pending.

### Remaining Work After Generation 85

1. Deploy the next supported generation, observe the exact mismatch, and register any distinct
   behavior correction before changing the recovery predicate.
2. Revalidate and record the terminal crossing.

### Value-Free Discriminator Checkpoint (2026-08-28)

The private Authority log now classifies only fixed vocabulary: legacy/current schema; each owner,
fence, target, generation, request, and plan binding as match/mismatch; the deadline as
not-forward/forward-active/forward-expired; and canonical receipt bindings as
legacy-unavailable/match/mismatch. It serializes no retained value. Exact unit assertions cover a
legacy active-deadline refusal and a canonical binding-drift refusal, and the complete focused
AWS-admin suite remains **27/27**. All **4711** primary cases and the **27/33/31** auxiliary suites
pass; canonical `prodbox dev check` reports `No hints` and completes its warning-clean all-target
build. Refreshed binary
`sha256:4f6269ef84d78f746d3149d4058fb5748d6eb4e767c23b8cd51e123e98fced3e` is the Generation-86
qualification input. The recovery predicate is unchanged pending that observation.

### Generation-86 Classification (2026-08-28)

Generation 86 publishes local image
`sha256:06b04569d57a6e890e4e09af77a1b9809937ffcbada11276729f9c8b623bfaef`, registry manifest
`sha256:78775df4c8bb9d3a3a37b7ab970afb4dde2dff48a1b3037a89e870103360b13a`, and containerd OCI
manifest `sha256:6e28bc08a9220ce4e81cfcd58a5f0be262363dbef8bd9ea4520313281021bfbc` before the supported
reconcile exits 1 at the protected `prepared-target/outbox/divergent` response. The deployed
Authority's value-free log reports exactly
`prepared-target/outbox/divergent schema=legacy renewal=absent`. Thus the retained state is not an
expired `Prepared` predecessor and the one-step-ahead classifier is not reached. The preceding live
generation had already reached authorization before the worker parser exited and exact cleanup ran;
the separately registered stable counterexample is
`EXPIRED-NONPREPARED-AWS-ADMIN-2026-08-28` (Sprint `2.115`).

## Sprint 2.115: Recover an Expired Non-Prepared AWS-Admin Attempt [✅ Done]

**Status**: Done — Generation 90 recovers the exact expired `Authorized` attempt after independent
Job, Pod, and execution-journal absence, then reaches Sprint `2.116`'s distinct worker-receipt
decode boundary.
**Implementation**: `src/Prodbox/ControlPlane/AwsAdminAuthorizedRecoveryProduction.hs`,
`src/Prodbox/ControlPlane/AwsAdminProvisionerEndpoint.hs`,
`src/Prodbox/Lifecycle/CredentialProvisioner/AwsAdminAuthority.hs`,
`src/Prodbox/Lifecycle/CredentialProvisioner/AwsAdminExecutionVault.hs`, and the exact Job/Pod
observer and chart/RBAC projection required by the accepted recovery proof.
**Deployment qualification**: proven — Generation 90 advances the retained root session, applies
the read-only journal grant, observes journal absence, performs the bounded recovery transition,
and reaches worker execution before exact cleanup.
**Independent Validation**: a pure state-transition table plus injected execution-journal and
Kubernetes observers proves recovery is admitted only after the old deadline, exact immutable
request/plan equality, positive old Job/Pod absence, and a definitively absent execution journal.
No live Kubernetes, Vault, registry, or AWS effect is needed for that table.
**Docs to update**: `documents/engineering/lifecycle_control_plane_architecture.md`,
`documents/engineering/lifecycle_reconciliation_doctrine.md`, `DEVELOPMENT_PLAN/README.md`, and
`DEVELOPMENT_PLAN/00-overview.md`.

### Objective

Recover the observed prior authorized AWS-admin attempt only when it is impossible for that attempt
to have started an effect. The retained deadline must be expired, the Authority independently proves
the exact bound Job and Pod absent, and it additionally proves the permit-derived Vault execution
journal absent. These facts allow one CAS transition to a fresh binding-equivalent
`Prepared` intent; any present, initialized, corrupt, forbidden, or unobservable execution journal,
any live/unobservable workload, any active attempt, completed state, or binding drift remains a
closed refusal. Recovery never treats deadline expiry alone as worker quiescence.

### Deliverables

- Add a fixed-vocabulary private phase discriminator so the retained non-Prepared constructor is
  observed rather than inferred from `renewal=absent`.
- Define an opaque recovery proof derived only from independent exact Job/Pod absence and, for an
  authorized attempt, exact Vault execution-journal absence under the retained permit coordinate.
- Admit fresh preparation from only expired `Authorized` state carrying that proof and
  the existing immutable renewal bindings; preserve the outbox-before-state CAS/read-back order.
- Grant Lifecycle Authority only exact GET/read permissions needed for those two observations; it
  gains no credential value, Kubernetes mutation, or generic Vault read capability.
- Add two-sided fault tests for every reachable state phase, active/expired time, workload disposition,
  journal disposition, immutable binding, CAS response-loss, and outbox migration branch.

### Validation

1. The retained Generation-82 phase is identified by the deployed value-free discriminator.
2. The exhaustive transition table admits only an expired authorized no-effect proof.
3. Focused tests, all local suites, documentation/diff checks, and canonical `prodbox dev check`
   pass.
4. A fresh supported reconcile crosses `EXPIRED-NONPREPARED-AWS-ADMIN-2026-08-28`; any later
   distinct refusal is registered before behavior changes.

### Remaining Work

None.

### Phase-Discriminator Local Checkpoint (2026-08-28)

The endpoint records exactly one closed phase token before prepared-target publication:
`vacant`, `prepared`, `attested`, `authorized`, or `completed`. Both this message and the earlier
outbox discriminator route through the canonical output boundary and serialize no retained value.
The focused 2.115 assertion passes, the complete AWS-admin suite passes **28/28**, all **4712**
primary cases and the **27/33/31** auxiliary suites pass, and canonical `prodbox dev check` reports
`No hints` before its warning-clean all-target build. Binary
`sha256:79be50d53e64a184484bb2e6bb78e570964ba30c1aaa7d82f32d88eea000b0fa` is the Generation-87
diagnostic input; no recovery decision changes in this checkpoint.

### Generation-87 Constructor Evidence (2026-08-29)

Generation 87 publishes local image
`sha256:0bec934650b5a7aa4707de2b4b7c0e5f57cda6ac6a214121e0cdf70ed743c3d2`, registry manifest
`sha256:4f8012e1b2fbee4675ce3b18cf62fd61b3f7f5decd718a55d10091bfc051953c`, and containerd OCI
manifest `sha256:067d0e596d4bb466d18c339dbd11e6b86c7c29ae86381cfcba058cec4f7b492d`. The supported
reconcile exits 1 at the unchanged protected refusal. Its private log reports exactly
`aws-admin/prepare authority-phase=authorized` followed by
`prepared-target/outbox/divergent schema=legacy renewal=absent`. The recovery implementation may
therefore target the exact expired `Authorized` constructor; it need not infer or widen to another
phase.

### Bounded-Recovery Local Checkpoint (2026-08-29)

The opaque proof is mintable only from an expired exact `Authorized` state plus three independent
absence observations: named Kubernetes GET 404 for the signed-permit Job, named GET 404 for its Pod,
and authenticated Vault KV-v2 404 for the permit-derived execution-journal coordinate. Every
present, corrupt, unauthorized, timed-out, or otherwise unobservable result refuses; `Attested` and
`Completed` remain outside this recovery. The Credential Provisioner substrate now projects a
separate Lifecycle-Authority Role with only `get` on Jobs and Pods, and the Authority Vault policy
adds only `read` on the journal prefix. The endpoint trace proves absence observation, outbox
CAS/read-back, independent outbox read-back, then exact Authority CAS; exact replacement replay
closes a lost CAS response. Focused Sprint-2.115 assertions pass **5/5** and the complete AWS-admin
suite passes **31/31**. All **4716** primary cases and the **27/33/31** auxiliary suites pass;
canonical `prodbox dev check` reports `No hints` and completes its warning-clean all-target build.
Binary `sha256:497b9058f696fe155717da0858555ec68fd09a6da44c5b472e29dded0dbc6f30`
is the Generation-88 input. The installed integration suite reproduces only the already registered
Sprint-5.38 fake-Helm counterexample (**8/63** fail before their owned bodies); that later fixture
surface neither widens this recovery nor substitutes for its fresh supported deployment.

### Generation-88 Recovery-Boundary Evidence (2026-08-29)

Generation 88 publishes local image
`sha256:bacede1443d0ab5be8480ea5bf93b6b3dd7f5ab0bac3715eb1658b9be2a92bfb`, registry manifest
`sha256:0fa90432116a435dd2fe418dfffb39c725ab3c75654b858e54db00c144cba575`, and containerd OCI
manifest `sha256:8261c3fcfe76945815d9e846dfa47119079e820e9634eeab724287f23b4bf70c`.
The fresh supported reconcile crosses the old legacy-outbox refusal, independently installs the
GET-only observer Role/Binding, and then fails closed at
`attempt-recovery/journal-unobservable`. Read-only live checks prove the Authority subject can
`get` Jobs and Pods but cannot `list`, both exact workload kinds are absent, and the fresh Authority
Pod reports only `authority-phase=authorized`; therefore the distinct stable counterexample is
`AUTHORIZED-JOURNAL-UNOBSERVABLE-2026-08-29`. The next step classifies only the Vault session/request
boundary with a closed value-free token; it does not interpret this generic result as absence or
broaden the proof.

### Journal-Boundary Diagnostic Local Checkpoint (2026-08-29)

The execution-journal observer now distinguishes exact absence and presence from fifteen closed,
value-free Vault session/request outcomes: acquisition and relogin sealed/forbidden/unavailable;
request unauthorized, client failure, server failure, unexpected status, connection failure,
timeout, and decode failure. Any successful journal read, including a corrupt value, remains
`present`; only KV-v2 404 is `absent`; every other token still projects to the existing
`journal-unobservable` recovery refusal. The production observer emits exactly one closed token
through the canonical diagnostic boundary before making that projection. Focused Sprint-2.115
assertions pass **5/5** and the complete AWS-admin suite passes **31/31**. All **4716** primary
cases and the **27/33/31** auxiliary suites pass; canonical `prodbox dev check` reports `No hints`
and completes its warning-clean all-target build. Binary
`sha256:a1211a9a12b0875fc986e8ea19fe2dca9f3194b2b7c6930267c4ffa0c75b7230` is the Generation-89
input. That generation is diagnostic only: it must identify the live Vault boundary before any
behavior is changed.

### Generation-89 Journal-Boundary Evidence (2026-08-29)

Generation 89 publishes local image
`sha256:dbd78bc6e7d58f3accce1cf5c735d65764a9ac712734fefb6ab3495e4f60337f`, registry manifest
`sha256:1b0466fc3c6cd7b085ff2bdfd70b4cbf42d4bba2251bad307cd0cce1a94bee1c`, and containerd OCI
manifest `sha256:50731bb28cbf5daf7f1221b7012dc0467a2e7117cd53b88bcf40ced25670ff8b`.
Both the Bootstrap Broker and Lifecycle Authority execute that exact local image with fresh Pods;
the latter is Ready 1/1 with zero restarts and reports
`aws-admin/recovery journal-observation=request/unauthorized`. A value-free Vault
self-capability comparison under the exact `prodbox-lifecycle-authority` Kubernetes identity shows
`read` on the known MinIO coordinate and `deny` on a journal-prefix child. Thus session login and
request construction are not the defect: the live policy document is stale.

The source policy is wider, but the retained completed root-baseline receipt still names the
unchanged current target set, so its terminal replay suppresses policy reapplication. The narrow
correction is the established append-only migration: add one semantic target for the
Lifecycle-Authority AWS-admin journal observer and admit only the exact immediately preceding
closed receipt as restart input. It must advance the root-session identity, run the normal
generated-root baseline, and leave every partial or in-progress old target set corrupt.

### Baseline-Currentness Local Checkpoint (2026-08-29)

`BaselineLifecycleAuthorityAwsAdminJournalObserver` is appended after every existing durable tag.
The retained-store validator accepts the exact preceding 17-target receipt only in
`RootSessionClosed`; current construction and every in-progress phase require all 18 targets. The
production evidence plan therefore mints a fresh root-session identity and enters the existing
orphan-cleanup/generated-root program before policy reconciliation. A test-local pre-2.115 wire
type proves byte compatibility without constructing old evidence through the widened production
API. Focused Sprint-2.115 cases pass **6/6**, the complete root-session crash matrix passes
**14/14**, and AWS-admin remains **31/31**. All **4717** primary cases and the **27/33/31**
auxiliary suites pass; canonical `prodbox dev check` reports `No hints` and completes its
warning-clean all-target build. Binary
`sha256:a8a68e3b1c28b98326c46dbeccc600751eb04cac853578019bd4796a1bdf8adc` is the Generation-90
qualification input.

### Generation-90 Recovery Crossing (2026-08-29)

Generation 90 publishes local image
`sha256:4ac2fcf50ed9018bec69fd84134f017ad31d47a9f879b2578c4dc6d22472baa3`, registry manifest
`sha256:4e419402cb48f096c557219a8aa945eb7734519c0dfc4eb809f71526f9689eb9`, and containerd OCI
manifest `sha256:231d33c6e8db7cf79a28067c86fb1214d7e508fbfd043dfa376c789c4e55c09e`.
The generated-root program advances `root-session-69894281…` to `root-session-50cf8517…` and
completes baseline read-back. The fresh Authority Pod is Ready 1/1 with zero restarts, logs exact
`journal-observation=absent`, and its configured identity's self-capabilities report `read` for
both the known MinIO coordinate and the journal-prefix child. The recovered attempt then creates
and runs its worker; failure cleanup leaves no matching Job or Pod. Its next distinct public result
is `AwsAdminCoordinatorReceiptRejected AwsAdminWorkerReceiptDecodeFailed`, registered as stable
counterexample `AWS-ADMIN-WORKER-RECEIPT-DECODE-2026-08-29` under Sprint `2.116`. The 2.115
recovery and deployment qualification are therefore complete without treating the later receipt
as valid.

## Sprint 2.116: Classify AWS-Admin Worker Receipt Transport Decode [✅ Done]

**Status**: Done — Generation 126 crosses the corrected Target-worker receipt and delivery path;
the later Authority Backup export-response refusal is registered separately under Sprint `2.117`.
**Implementation**: `src/Prodbox/Lifecycle/CredentialProvisioner/AwsAdminExecution.hs`,
`src/Prodbox/Lifecycle/CredentialProvisioner/AwsAdminKubernetes.hs`, and focused validation under
`test/unit/CredentialProvisionerAwsAdminAuthority.hs`.
**Deployment qualification**: proven — Generation 126 crosses the complete worker receipt and
Target delivery path under the supported reconcile.
**Independent Validation**: a pure value-free classifier over bounded captured bytes distinguishes
empty, within-bound, and oversize output plus raw and single-line-ending decode dispositions. Its
table can be exhaustive without Kubernetes, Vault, AWS, or credential material.
**Docs to update**: `documents/engineering/lifecycle_control_plane_architecture.md`,
`documents/engineering/lifecycle_reconciliation_doctrine.md`, `DEVELOPMENT_PLAN/README.md`, and
`DEVELOPMENT_PLAN/00-overview.md`.

### Objective

Identify the exact transport shape that turns a successful AWS-admin worker exit into
`AwsAdminWorkerReceiptDecodeFailed`, without logging receipt bytes, identifiers, lengths, or
credential material and without accepting a modified encoding before live evidence licenses it.

### Deliverables

- Add one closed value-free classifier for captured stdout: empty, within-bound, or oversize; raw
  canonical decode result; and decode result after removing exactly one terminal line ending.
- Emit the classifier only at the protected coordinator boundary while preserving the existing
  public error and exact Job/Pod cleanup.
- Add two-sided tests covering canonical binary output, empty/malformed/oversize output, LF/CRLF,
  valid receipt plus extra bytes, and all existing receipt decoder errors.
- Deploy the diagnostic, observe the exact constructor, and correct only that transport shape.

### Local Diagnostic Checkpoint (2026-08-29)

The bounded receipt decoder now projects a closed transport observation containing only
empty/within-bound/oversize, one of its six decoder dispositions, absent/LF/CRLF terminal ending,
and the decoder disposition after removing exactly one present ending. The production Kubernetes
adapter writes that protected token only after successful attach and returns the original bytes
unchanged to the existing coordinator decoder and cleanup fold. The table covers canonical,
empty, malformed, oversize, LF, CRLF, extra-byte, unsupported-version, and semantic-invalid
captures. It also proves that a trailing line ending or other trailing byte parses far enough to
produce `non-canonical`, not Generation 90's earlier `decode-failed`; no normalization is admitted.
The focused Sprint-2.116 case passes **1/1** and the full AWS-admin Authority group passes
**32/32**. All **4718** primary cases and the **27/33/31** auxiliary authority suites pass;
repository-pinned Fourmolu/HLint reports `No hints`, documentation/policy and diff checks pass,
and the warning-clean all-target canonical `prodbox dev check` exits 0. Binary
`sha256:4cf6f072f730c4a6515efb60c2e2de30e9432ae3aa2550b5fc70a99a74dd409a` is the Generation-91
diagnostic input. Deployment validation remains outstanding.

### Generation-94 Single Non-Envelope Line Classification (2026-08-29)

Generation 94 publishes local image
`sha256:3a1f6d76adad52c0d85356753b601d0d7333572291c3bcdd24c5910a0a0ac73a`, registry manifest
`sha256:150f6b70a1a4272c4f307a9fdbcc9e2660d2cabb472d22bad65dd7b38c2afd45`, and containerd OCI
manifest `sha256:885ef30b11ca0eda1086bc2a8f658f87feea200658d17039f586999b8923c27d`.
The retained root session remains current, the worker is reached, and the Pod-log token refines to
exactly `line-topology=single/receipt-envelope-lines=none`; the Authority then cleans up and returns
the unchanged public decode refusal. Stable counterexample
`AWS-ADMIN-WORKER-POD-LOG-SINGLE-NON-ENVELOPE-2026-08-29` proves that no exact receipt envelope is
available as a whole line and therefore forbids substring selection. The narrow correction writes
one explicit record separator followed by a fixed-version canonical envelope line and admits only
one unique exact line whose envelope and inner receipt both decode canonically. No match or multiple
matches refuse.

### Record-Separated Envelope Local Correction Checkpoint (2026-08-29)

The worker now precedes the fixed `prodbox-aws-admin-worker-receipt-v1:` canonical-base64 envelope
line with one LF record separator. Attach accepts only the exact separator plus envelope and no
other line or ending. The Pod-log path requires the observed final LF, rejects CRLF and repeated
final endings, and selects only one unique whole line whose fixed-version envelope and unchanged
inner receipt both decode canonically. Joined same-line contamination, no match, and multiple
matches refuse; no substring is selected. The first focused run caught and closed the repeated-LF
arm before the checkpoint. Focused Sprint-2.116 passes **3/3** and the complete AWS-admin group
passes **34/34**. All **4720** primary cases and the **27/33/31** auxiliary authority suites pass;
repository-pinned Fourmolu/HLint reports `No hints`, documentation/policy and diff checks pass,
and the warning-clean all-target canonical `prodbox dev check` exits 0. Binary
`sha256:055567dc5e46bc6fb4099062b6bd8120dc333af4a86181fef0e4f232a5841392` is the Generation-95
qualification input. Deployment validation remains outstanding.

### Exact-Current Image-Import Bypass Local Checkpoint (2026-08-29)

The home-local image path now observes `docker image inspect` and `ctr images inspect` only after a
successful registry push and Docker pull. It skips archive creation and containerd import exactly
when both observations name the same runtime tag and the canonical Docker config digest equals the
one unique canonical OCI config digest in containerd's inspection. Mismatch, either failed
observation, malformed or noncanonical digest, absent config, wrong tag, ambiguous config lines,
and repeated Docker-output endings all retain the existing import. The focused two-sided table
passes **1/1**, all **4721** primary cases and the **27/33/31** auxiliary authority suites pass,
repository-pinned Fourmolu/HLint reports `No hints`, documentation/policy and diff checks pass, and
an explicit terminal rerun of canonical `prodbox dev check` exits 0. Binary
`sha256:bf30f402437e4c9920907c2d11f821dbff1a423edffa88662f26e170dc3500a3` is the Generation-96
qualification input. Generation 96's first attempt performs the required mismatched-image import
without inducing disk pressure and reaches a created-and-cleaned genesis worker; terminal client
output lost to tool truncation is not a receipt and does not qualify the transport correction. Its
unchanged-source retry exposes stable counterexample
`LOCAL-RUNTIME-REIMPORT-CONFIG-MEDIA-TYPE-2026-08-29`: the exact containerd inspection carries the
matching canonical config digest under `application/vnd.docker.container.image.v1+json`, while the
observer recognizes only `application/vnd.oci.image.config.v1+json`, so it incorrectly starts a
second archive/import. The narrow correction admits exactly the Docker or OCI config media type,
still requires one unique canonical config digest equal to Docker's exact-tag image ID, and leaves
every failed, absent, wrong-tag, malformed, ambiguous, or unequal observation on mandatory import.

### Generation-96 Import and Active-Attempt Evidence (2026-08-29)

Generation 96 publishes local image
`sha256:14c72cbd35aa7ce83b2b9ce0bfb8ecb833555af98c36ae3608592e7c51ae9464`, registry manifest
`sha256:79de31887d5520a1c9caa165f605cb66e66fef1ab7a5f9a399fe0e09981728c7`, and import manifest
`sha256:d1b959ffe7762e8d6287bda489f1a7acb6e6f0f856a045b6f22195327ecd7275`. The required
mismatched-image import remains pressure-free: registry stays reachable, the node retains
`DiskPressure=False`, and the run crosses baseline through a created-and-cleaned genesis worker.
Its terminal client output is lost to tool truncation and is therefore not a receipt. The exact
containerd inspection then proves the tag carries matching Docker config digest
`sha256:14c72cbd…` under `application/vnd.docker.container.image.v1+json`.

An unchanged-source retry incorrectly selects archive/import again and reaches the expected
active-attempt fence
`AwsAdminCoordinatorPrepareFailed (AwsAdminProvisionerClientUnavailable
"prepared-target/outbox/divergent")`. The deployed value-free log reports exactly
`aws-admin/prepare authority-phase=authorized` and
`prepared-target/outbox/divergent schema=current renewal=absent`: the first attempt's new permit is
still active, so the expired-attempt absence proof is deliberately unavailable and no second worker
runs. This bounded precondition licenses waiting for expiry and then using the existing exact
recovery; it does not license weakening the active fence.

### Docker-Archive Config-Media-Type Local Correction Checkpoint (2026-08-29)

The exact-current observer now admits exactly
`application/vnd.docker.container.image.v1+json` or
`application/vnd.oci.image.config.v1+json` as a containerd config descriptor. It still requires one
unique canonical digest under the exact requested tag and equality with Docker's independently
observed exact-tag image ID. Mixed Docker/OCI descriptors are ambiguous and refuse; an unknown
config media type, failed observation, absent config, wrong tag, malformed digest, or unequal digest
retains mandatory import. The production-shaped focused case passes **1/1**, all **4721** primary
cases and the **27/33/31** auxiliary authority suites pass; repository-pinned Fourmolu/HLint reports
`No hints`, documentation/policy and diff checks pass, and canonical `prodbox dev check` exits 0.
Binary `sha256:56527de2ae835c21c9bb5ae403f6ae412ccfa576525c69a830e356d35dbbf08f` is the Generation-97
qualification input.

### Generation-97 Recovered Receipt Counterexample (2026-08-29)

Generation 97 publishes local image
`sha256:b2a58272b8076d96da19b166de0f117bd0cc2e49c7dd6c8942b61aa5060cab38`, registry manifest
`sha256:f30e8df0ac69c7651bcc5bc9c172725eda472c7ce5f5392c3911db0d5d3e2dce`, and import manifest
`sha256:201762ec340fbac1afc91dad567481fafdc945958fd5e6b9a79376206169ce24`. Because the image is
genuinely changed, the corrected observer retains mandatory import. Export/import completes in
239.1 seconds, registry remains reachable, and the node remains `DiskPressure=False`; this proves
the mandatory arm was not weakened. The expired Generation-96 permit then recovers through exact
Job, Pod, and execution-journal absence before a new worker runs.

Attach is empty. The exact Pod-log diagnostic is
`source=pod-log/size=within-bound/raw=decode-failed/raw-envelope=invalid/terminal-ending=lf/without-terminal-ending=decode-failed/without-terminal-ending-envelope=invalid/line-topology=single/receipt-envelope-lines=none`,
followed by public `AwsAdminWorkerReceiptDecodeFailed`. Stable counterexample
`AWS-ADMIN-WORKER-POD-LOG-RECORD-ENVELOPE-ABSENT-2026-08-29` proves the record-separated writer did
not arrive as a canonical envelope line, but not why. The next diagnostic may report only whether
the one line begins with the fixed receipt-envelope prefix and, if absent, whether it belongs to a
closed worker terminal-output cause vocabulary. It must not expose the line, bytes, values, counts,
or select a substring as a receipt.

### Generation-97 Exact-Current Live Proof (2026-08-29)

The immediate unchanged-source retry rebuilds entirely from cache, republishes the same local image
and registry manifest, and prints exact proof
`RKE2 containerd runtime image already current: 127.0.0.1:30080/prodbox/prodbox-runtime:prodbox-3349a232b3454fb3be77b2f68919904f`.
No archive or import process exists. The run then reaches only the expected active-`Authorized`
`prepared-target/outbox/divergent` fence. Together with the preceding changed-image import, this
live-qualifies both mandatory-import and exact-current-skip arms without weakening an unobservable,
stale, malformed, or mismatched case.

### Prefix and Worker-Terminal Diagnostic Local Checkpoint (2026-08-29)

The protected observation now adds none/unique/ambiguous fixed receipt-prefix lines and one closed
worker-terminal field. Its 20 causes correspond exactly to the worker error constructors; sizes,
ingress versions, nested decoder details, and exception text collapse to their constructor at the
worker output boundary before the line enters the Pod log. Exact unknown and multiple-terminal-line
arms refuse. A fixed-prefix line still is not selected unless the existing canonical envelope and
inner receipt checks pass. Focused Sprint-2.116 passes **3/3**, the complete AWS-admin group passes
**34/34**, all **4721** primary cases and the **27/33/31** auxiliary authority suites pass;
repository-pinned Fourmolu/HLint reports `No hints`, documentation/policy and diff checks pass, and
canonical `prodbox dev check` exits 0. Binary
`sha256:3bd6130bf81d26ac0fe6b9795dec751fadd4a6fcc250c8d892de0ebcf559fb0b` is the Generation-98
diagnostic input. The retained permit prepared at 10:57:58 EDT remains actively fenced until its
11:27:58 deadline.

### Generation-98 Completion-Publication Counterexample (2026-08-29)

Generation 98 publishes local image
`sha256:71b970611f2b8cc664753b47c6ea379aee96474959c5bbae502bffb6ad94de45`, registry manifest
`sha256:d01e5a9fbf4906c7196e8fd4a883318d388f884cc251d427e95ba2a3a1b87929`, and containerd import
manifest `sha256:fd29a7fd54556340f9bd666a886e10ce6c5a98a2fe85a7a834b6fe6ec9c3acef`. The changed image
correctly selects mandatory import, which completes in 239.4 seconds with 57 GB host storage free
and `DiskPressure=False`. The retained Generation-97 attempt recovers through exact absence and the
new worker runs.

The attach token is exactly
`source=attach/size=empty/raw=decode-failed/raw-envelope=invalid/terminal-ending=absent/without-terminal-ending=not-applicable/without-terminal-ending-envelope=not-applicable/line-topology=empty/receipt-envelope-lines=none/receipt-prefix-lines=none/worker-terminal-line=none`.
The Pod-log token is exactly
`source=pod-log/size=within-bound/raw=decode-failed/raw-envelope=invalid/terminal-ending=lf/without-terminal-ending=decode-failed/without-terminal-ending-envelope=invalid/line-topology=single/receipt-envelope-lines=none/receipt-prefix-lines=none/worker-terminal-line=completion-unavailable`.
The public result remains `AwsAdminWorkerReceiptDecodeFailed`. Stable counterexample
`AWS-ADMIN-WORKER-COMPLETION-UNAVAILABLE-2026-08-29` proves the single line is the worker's closed
completion-publication refusal, not a malformed fixed-prefix receipt. The next correction must be
derived from the completion path that produces `AwsAdminWorkerCompletionUnavailable`; it may not
weaken canonical receipt selection or expose terminal payloads.

### Delivery/Completion Principal Split Local Checkpoint (2026-08-29)

The exact failure is deterministic and occurs before the provider program. The production delivery
resolver constructed its active Authority client by calling `completionTransport` with the
accessor-bearing worker session. That session intentionally lacks the completion signing key,
because completion is permitted only after its accessor is proven absent, so signer resolution
collapsed to `AwsAdminWorkerCompletionUnavailable` before delivery or execution began.

The correction preserves the stable Credential Provisioner delivery principal at wire code 103 and
appends a distinct completion principal at code 104. The active worker policy contains only the
delivery Transit signing path; its caller may reach exactly Target material observation, Target
intent issue, and retained-material delivery, and cannot reach AWS-admin completion. The
post-revocation accessor-free batch policy contains only the completion signing path; its caller may
reach AWS-admin completion and none of the three delivery routes. Both worker identities are
forbidden from preparation, which remains operator/test-harness-only. The existing maximum route
trust fan-in remains three.

The complete AWS-admin group passes **34/34**, the Vault/session group passes **23/23**, all
**4721** primary cases and the **27/33/31** auxiliary authority suites pass. Repository-pinned
Fourmolu/HLint reports `No hints`, documentation/policy lint and `git diff --check` pass, and the
canonical warning-clean `prodbox dev check` exits 0. Binary
`sha256:6ee36ced07bc4e583902e1a7027ddc35946829e276d703d090b9a5d2479519d3` is the Generation-99
input. The live deployment is admitted after the conservative 12:29 EDT margin beyond the retained
Generation-98 permit window.

### Generation-99 Authority Trust-Read Counterexample (2026-08-29)

Generation 99 builds local image
`sha256:4501b90e504ba890e1d00290daf431588679129b9353046d0f877807eabd02e1` in 982.4 seconds and
publishes registry manifest
`sha256:b95a04f5e456096c79c2729f70c3523d9e78dfb1d17dc4e1ab1726032c8f29db`. Mandatory import
completes in 247.6 seconds at OCI manifest
`sha256:1e76c8f2bf6183f6af8f930337df83b41ef46455e63d2bc422e9f70584b960ee`. Baseline reconcile instead
reuses the retained pre-completion-inventory receipt under the already existing root session
`root-session-50cf8517683fe10487d57dc021de71f18fe458118c893c4be797876242f0dcff`.

The new image does not reach the expired-attempt or worker boundary. Exact-image Lifecycle Authority
Pod `8847825e-b00b-4403-bee8-517e2410a2bd` crash-loops with the protected payload-free startup cause
`authentication/trust-read/status-403`. Stable counterexample
`LIFECYCLE-AUTHORITY-TRUST-READ-403-2026-08-29` therefore moves the next investigation to the
Authority's public-key trust read for the appended completion caller. Source inspection proves the
new Transit key and exact derived policies are present in the desired baseline, but the receipt's
closed target set was not appended for this semantic revision; the old receipt can therefore
suppress their application. The counterexample licenses one append-only target that makes this
exact completion-principal/key/policy revision current. It does not license granting the Authority
a wildcard trust read, changing caller routes, or sharing the delivery/completion signing keys. The
supported reconcile exits 1 after the full 30-minute Helm bound, reports the exact-image StatefulSet
0/1 Ready with 10 restarts, and retains the failed non-terminal release as required. That exit is a
bounded convergence failure, not absence or completion evidence.

### Completion-Principal Baseline Revision Local Checkpoint (2026-08-29)

The closed correction appends `BaselineCredentialProvisionerCompletionPrincipal` as the sole new
baseline target. It names the new caller Transit key and the derived exact Authority, active-worker,
and batch-completion policy projections without widening any route or sharing either provisioner
key. The exact immediately preceding 18-target closed receipt is accepted only as historical
terminal evidence and restarts the baseline under a fresh root session. An in-progress predecessor
receipt and every partial predecessor target set remain refusals.

The focused root-session matrix passes **15/15**, the complete primary suite **4722/4722**, and the
auxiliary authority-admission, authentication, and authenticated-transport suites **27/33/31**.
Repository-pinned Fourmolu is applied, HLint reports `No hints`, documentation lint and
`git diff --check` pass, and canonical warning-clean `prodbox dev check` exits 0. Binary
`sha256:a21c7b64fa42e1e464f02ae2caf741012132f2531e2ac848a1ff6044e77723e9` is the Generation-100
input. Live qualification must prove that baseline reconciliation advances retained root session
`root-session-50cf8517683fe10487d57dc021de71f18fe458118c893c4be797876242f0dcff`, applies the appended
key and policies, brings the exact-image Lifecycle Authority Ready without
`authentication/trust-read/status-403`, and crosses worker recovery through the closed
delivery/completion split.

### Generation-100 Worker Execution-Failed Counterexample (2026-08-29)

Generation 100 builds local image
`sha256:5e1cef78bae4d76e407f9623ba7f77a0d70a88415cbb0f438254619303796f46` in 987.3 seconds and
publishes registry manifest
`sha256:5c9d1c5d1d58eeb22580821ca7ba2e0cdf52670ca3c4e99852818ed7ad3e0b4f`. Mandatory import
completes in 203.2 seconds at OCI manifest
`sha256:d806de3492d158d927f4c04076ae045624fee352185d4c59c14663b9d9d894af`.

The live baseline applies the appended target and advances retained root session
`root-session-50cf8517683fe10487d57dc021de71f18fe458118c893c4be797876242f0dcff` to
`root-session-3b9d57437d1b63cb471833be53bd9331dfa14cef89c151e67cde742140a69559` with read-back digest
`a57561193057a71d62986c9dcc39ca5d59274bd464a413ef445ed3a3b9f77df6`. Lifecycle Authority
crosses protected startup, closing the Generation-99 trust-read 403, and recovery reaches the
AWS-admin worker. Attach is empty. The bounded Pod-log fallback observes exactly one non-receipt
line and emits
`source=pod-log/line-topology=single/receipt-envelope-lines=none/receipt-prefix-lines=none/worker-terminal-line=execution-failed`.
The unchanged public failure is `AwsAdminWorkerReceiptDecodeFailed`.

Stable counterexample `AWS-ADMIN-WORKER-EXECUTION-FAILED-2026-08-29` moves the investigation to
the protected worker execution refusal. It licenses no capability widening, alternate receipt
transport, or reinterpretation of the terminal marker before the exact execution cause is
established from retained/read-only evidence.

Read-only inspection after the supported exit proves Lifecycle Authority Pod
`b22aa8d6-2a08-4d9f-a3a5-e7ec18d20861` is Running/Ready with zero restarts on exact local image
`sha256:5e1cef78bae4d76e407f9623ba7f77a0d70a88415cbb0f438254619303796f46`; the failed
credential Job/Pod is already absent. Source inspection proves `executeAuthenticated` discards the
closed `AwsAdminExecutionError` constructor and emits one generic execution marker, so the
available retained evidence cannot distinguish journal, IAM, or delivery refusal. The
counterexample licenses only an exhaustive mapping of those closed constructors to payload-free
terminal subcauses. It does not license exposing boundary text, changing execution or cleanup,
adding a retry, widening a route/policy, or accepting a non-receipt line as a receipt.

### Worker Execution-Cause Diagnostic Local Checkpoint (2026-08-29)

`AwsAdminWorkerExecutionCause` is exhaustive over the closed execution-error algebra, and the
terminal grammar now renders `execution-failed/<subcause>`. The mapping strips every `Text`, count,
codec version, and nested material error before rendering. An explicit regression proves two
different journal boundary payloads produce the same `journal-unavailable` token; representative
IAM prerequisite/count and target-delivery errors likewise retain only their closed constructor.
Execution state transitions, IAM and delivery interpreters, receipt decoding, Job/Pod cleanup,
routes, and Vault policies are unchanged.

The complete AWS-admin group passes **35/35**, all **4723/4723** primary cases pass, and the
auxiliary admission/authentication suites pass **27/33/31**. Repository-pinned Fourmolu is applied,
HLint reports `No hints`, documentation lint and `git diff --check` pass, and canonical
warning-clean `prodbox dev check` exits 0. Binary
`sha256:3bf3381e3dd28bb863f5e45a5bea62655c00f2984a3804d4b09ef57a69649071` is the Generation-101
input. Live qualification must preserve root session `root-session-3b9d5743…`, recover the expired
Generation-100 attempt only after exact Job, Pod, and execution-journal absence, and name exactly
one payload-free execution subcause before any behavioral correction.

### Generation-101 Journal-Present Recovery Counterexample (2026-08-29)

Generation 101 builds local image
`sha256:c56baffafcb3e5bee51a7214e1e90ed5ad602e52c4ab78e9a973542383beb8c2` in 994.8 seconds,
publishes registry manifest
`sha256:04f7565c62a40a8620a6305b64403002c5522661f205ae23ffbb3bce88374175`, and completes the
mandatory 223.5-second import at OCI manifest
`sha256:81645f2d48de89f46bcbddf0b35174c30b611a4bea2924009c3322d2bf9ae8d7`. Baseline reconciliation
retains exact current root session `root-session-3b9d5743…` and read-back digest `a5756119…`.

The reconcile does not create a Generation-101 credential worker. The Generation-100 Authorized
attempt is expired and its exact Job and Pod have been cleaned, but its permit-derived execution
journal is present. The existing no-effect observer therefore refuses at
`attempt-recovery/journal-present`, producing public failure
`AwsAdminCoordinatorPrepareFailed (AwsAdminProvisionerClientUnavailable ...)`. Stable
counterexample `AWS-ADMIN-AUTHORIZED-RECOVERY-JOURNAL-PRESENT-2026-08-29` moves the investigation
to the durable continuation contract for an Authorized attempt whose worker has committed journal
evidence. It does not license classifying presence as absence, deleting that evidence, replacing
the permit, or restarting IAM effects from a fresh journal.

Source inspection proves the Sprint-2.115 production observer intentionally collapses every
successful journal read to `Present` without decoding it. That was sufficient and load-bearing for
the no-effect recovery proof, but it cannot choose a durable continuation: the retained object may
be at intent, create-attempt, key-created, target-committed, cleanup-required, cleanup-proven, or
complete. The counterexample therefore licenses one read-only exhaustive payload-free classifier
for those exact phases under embedded-permit equality. Absence remains the sole no-effect proof;
corrupt bytes, a permit mismatch, and every session/request failure remain distinct refusals. The
diagnostic grants no write/delete capability and performs no recovery transition or provider
effect.

### Journal-Present Phase Diagnostic Local Checkpoint (2026-08-29)

The production observer now uses its existing one exact permit-derived Vault read to distinguish
absence; all seven canonical phases; the initial-attempt/remint-used bit; embedded-permit mismatch;
invalid bytes; and the closed session/request failure family. It renders only those bounded tokens.
Absence remains the only input that can mint the Sprint-2.115 no-effect proof; every present phase,
invalid/mismatched value, and unobservable read still refuses. The observer has no write/delete
boundary and performs no Authority transition, Kubernetes mutation, or provider effect.

The complete AWS-admin group passes **35/35**, all **4723/4723** primary cases pass, and the
auxiliary admission/authentication suites pass **27/33/31**. Repository-pinned Fourmolu is applied,
HLint reports `No hints`, documentation lint and `git diff --check` pass, and canonical
warning-clean `prodbox dev check` exits 0. Binary
`sha256:e90cb98f4460dad96f13806163f382ef878958f1361a940cb9200e49abca7652` is the Generation-102
input. Live qualification must retain root session `root-session-3b9d5743…`, create no credential
worker, leave the retained journal unchanged, and report its exact payload-free phase.

### Generation-102 Intent-Committed Recovery Counterexample (2026-08-29)

Generation 102 builds local image
`sha256:c9b64a3f80d8a27ff75215ec83ce56404b2a4857393b40a3d93e29cb02805305`; its compile stage
completes in 1002.2 seconds. It publishes registry manifest
`sha256:8dc29aa451632fe83d4168badf10f16d2f0c31a5d0a95e4630604df3cb969a74` and completes the
223.5-second containerd import at OCI manifest
`sha256:04d74efe51031bb37301e773be7a24594f1bc511c4a5afed6460b06e368204ea`. Baseline
reconciliation retains root session `root-session-3b9d57437d1b63cb471833be53bd9331dfa14cef89c151e67cde742140a69559`
and read-back digest `a57561193057a71d62986c9dcc39ca5d59274bd464a413ef445ed3a3b9f77df6`.
The exact-image Lifecycle Authority is Running/Ready with zero restarts.

The supported reconcile creates no credential worker and exits 1 at the unchanged public
`attempt-recovery/journal-present` refusal. The protected read-only observation is exactly
`aws-admin/recovery journal-observation=present/intent-committed/initial-attempt`. Stable
refinement `AWS-ADMIN-AUTHORIZED-RECOVERY-INTENT-COMMITTED-2026-08-29` establishes that the
retained first-attempt journal stopped after durable intent and before its create-attempt phase.
The absence of a later durable phase is not provider-absence evidence. This counterexample
licenses only an exact continuation tied to the same Authorized attempt and retained intent;
deleting the journal, treating presence as the Sprint-2.115 no-effect proof, or minting an
unrelated replacement attempt remains forbidden.

### Intent-Committed Durable Continuation Local Checkpoint (2026-08-29)

Exact Job and Pod absence remain mandatory. The production recovery classifier admits
authenticated execution-journal absence or only the canonical, embedded-permit-equal
`intent-committed/initial-attempt` phase. Remint intent, every later phase, permit mismatch,
invalid bytes, and session/request unobservability all retain the existing refusal. The admitted
phase may have applied idempotent bucket/IAM prerequisite reconciliation, but the execution
machine cannot create an access key before durably committing `create-attempt-prepared`. Recovery
therefore uses the existing immutable-binding-equivalent Authorized-to-Prepared renewal, retains
the predecessor journal as evidence, and lets the fresh permit initialize its own journal.

The focused Sprint-2.116 group passes **7/7**, the complete AWS-admin group passes **35/35**, all
**4723/4723** primary cases pass, and auxiliary admission/authentication suites pass **27/33/31**.
Repository-pinned Fourmolu is applied, HLint reports `No hints`, documentation lint and
`git diff --check` pass, and canonical warning-clean `prodbox dev check` exits 0. Binary
`sha256:81ebde0f6662257bfeacf53b224538cf7cd1310df52e74c37aaa1a61cf2e6002` is the Generation-103
input. The next supported reconcile must retain the predecessor journal, cross only through a
fresh binding-equivalent permit, and qualify the worker receipt or register its next exact
counterexample.

### Generation-103 IAM-Prerequisite Counterexample (2026-08-29)

Generation 103 builds local image
`sha256:9db85e6dd61eba87cb6c95b6d662587a1173c5e78b7d141df03b996c09f34822`; its compile stage
completes in 991.7 seconds. It publishes registry manifest
`sha256:462dd3c25e78767d1a430249d284eb64be52b6e55746d221ad099ab11e720394` and completes the
225.8-second containerd import at OCI manifest
`sha256:9f1e75ccc75a5e1f775f46bfbf96c788a2676ae82a7cb45894f9affca9e0225a`. Baseline
reconciliation retains root session `root-session-3b9d57437d1b63cb471833be53bd9331dfa14cef89c151e67cde742140a69559`
and read-back digest `a57561193057a71d62986c9dcc39ca5d59274bd464a413ef445ed3a3b9f77df6`.
The exact-image Lifecycle Authority is Running/Ready with zero restarts.

Its protected recovery log proves the old `present/intent-committed/initial-attempt` journal enters
the exact recovery proof. The supported reconcile creates and cleans the fresh
binding-equivalent worker. Attach is empty and the exact Pod-log classifier ends at
`worker-terminal-line=execution-failed/iam-prerequisite-failed`; the public result remains
`AwsAdminWorkerReceiptDecodeFailed`. Stable counterexample
`AWS-ADMIN-WORKER-IAM-PREREQUISITE-FAILED-2026-08-29` establishes that intent continuation works
and moves the next investigation inside prerequisite reconciliation.

The production IAM boundary currently converts every `ProductionIamError` to bounded text before
constructing `AwsAdminIamPrerequisiteFailed`. That loses the closed distinction among credential,
bucket, IAM user, tags, inline policy, role, material, joint-disposition, and AWS-client failures.
The counterexample licenses only an exhaustive value-free prerequisite subcause derived before
that text conversion and carried to the protected worker terminal token. It licenses no provider
mutation change, policy widening, new retry, or new capability.

### IAM-Prerequisite Diagnostic Local Checkpoint (2026-08-29)

`ProductionIamError` is classified before the production boundary renders private text. Every
closed error constructor has one value-free cause. A native AWS failure additionally records only
the closed authored operation stage and a closed signing, transport, service, response-parse, or
ambiguity class. Known AWS service codes map to finite semantic categories; unknown operation
labels and service codes retain explicit fail-closed fallbacks. Credential values, IAM names,
provider messages, request IDs, response bodies, counts, and boundary detail cannot reach the
terminal Pod-log token. The change does not alter an IAM program, request, retry, permission,
journal transition, execution transition, cleanup, or receipt rule.

Focused Sprint-2.116 passes **8/8**, the complete AWS-admin group passes **36/36**, all
**4724/4724** primary cases pass, and auxiliary admission/authentication suites pass
**27/33/31**. Repository-pinned Fourmolu is applied, HLint reports `No hints`, documentation lint
and `git diff --check` pass, and canonical warning-clean `prodbox dev check` exits 0. Binary
`sha256:5538a7f75a37685882f283c2eccebcd2cb095dc36cfb784cff6cd83142d05a9e` is the
Generation-104 input. The next supported reconcile must preserve the retained predecessor journal
and name the exact live IAM prerequisite refusal before any behavioral correction.

### Generation-104 Observe-Bucket Service Counterexample (2026-08-29)

Generation 104 builds local image
`sha256:62beb581dd38fb3691b152f391eedaef063ffc9de25280eec4d8d259677c5d98`; its compile stage
completes in 987.3 seconds. It publishes registry manifest
`sha256:865155c3761e68717a6abe045cd8141a12fe32f42d44dd46893cb2637e560ac2` and completes the
200.2-second containerd import at OCI manifest
`sha256:a6427e11d7bcee76598ebb99aa03927a610ebab25dda8712c5dcc86bd8e06cc6`. Baseline
reconciliation retains root session `root-session-3b9d57437d1b63cb471833be53bd9331dfa14cef89c151e67cde742140a69559`
and read-back digest `a57561193057a71d62986c9dcc39ca5d59274bd464a413ef445ed3a3b9f77df6`.
The exact-image Lifecycle Authority is Running/Ready with zero restarts.

The old `present/intent-committed/initial-attempt` journal again enters the exact recovery proof.
The fresh worker is cleaned. Attach is empty and the protected Pod-log classifier ends at
`worker-terminal-line=execution-failed/iam-prerequisite-failed/aws/observe-bucket/service/other-client`.
The public result remains `AwsAdminWorkerReceiptDecodeFailed`; the supported command exits 1 after
1784.45 seconds. Stable counterexample
`AWS-ADMIN-OBSERVE-BUCKET-SERVICE-OTHER-CLIENT-2026-08-29` establishes that the prerequisite
refusal is an unrecognised 4xx native S3 service fault while observing the create-and-harden
long-lived bucket. It licenses only the read-only/source diagnosis and closed value-free
refinement needed to identify that exact refusal. It does not license an IAM behavior change,
retry, permission widening, capability addition, or propagation of provider detail.

### Native-S3 Payload-Hash Local Correction Checkpoint (2026-08-29)

Read-only diagnosis separates the live coordinate from the native request implementation. The
repository credential succeeds against native STS; read-only bucket listing proves the configured
long-lived bucket is owned; and read-only location observation proves it is in the configured
`us-west-2` region. The native `HeadBucket` response has no error body from which to refine an AWS
service code. Source comparison instead finds that `Prodbox.Aws.Native.S3` omitted the mandatory
`x-amz-content-sha256` header from every S3 SigV4 request even though the shared SigV4 doctrine,
the dedicated Authority store, and the MinIO signer already carry it. The narrow correction now
hashes the exact request body, sends that hash in `x-amz-content-sha256`, and includes the header in
the signed-header set for every native S3 HEAD, GET, and PUT. It changes no IAM program, policy,
retry, permission, capability, journal transition, or bucket-hardening document.

The new request-capture regression passes **1/1** and binds the empty `HeadBucket` body plus all
five hardening PUT bodies to their exact hashes and signed headers. The complete S3 hardening group
passes **6/6**, focused Sprint-2.116 passes **8/8**, the exact AWS-admin Authority group passes
**36/36**, all **4725/4725** primary cases pass, and auxiliary admission/authentication suites pass
**27/33/31**. Repository-pinned Fourmolu is applied, HLint reports `No hints`, documentation lint
and `git diff --check` pass, and canonical warning-clean `prodbox dev check` exits 0 after 8:56.
Binary
`sha256:8755f175a66db556982e7cdb1bc4b9a941c064ac80a6db58ffda6ca4585294b6` is the
qualified Generation-105 input; the gate-built executable is byte-identical to that recorded
binary.

### Generation-105 Target-Observation Counterexample (2026-08-29)

Generation 105 builds local image
`sha256:d7d89410c8407da78f627a212ea5e453215f87bf98d59f9f66b5b7f40bc914f5` in 991.6 seconds,
publishes registry manifest
`sha256:5e8cfd53b238be314229a4fbc4d0993691009976c5b81ab5b4ab35b3a5518a82`, and completes the
249.0-second containerd import at OCI manifest
`sha256:48facd9969100a51408cadd404c3cd2ebad620a59650d53d48daab2aa6e5b088`. Baseline
reconciliation retains root session `root-session-3b9d57437d1b63cb471833be53bd9331dfa14cef89c151e67cde742140a69559`
and read-back digest `a57561193057a71d62986c9dcc39ca5d59274bd464a413ef445ed3a3b9f77df6`.
Read-only post-exit observation proves the exact local-image Lifecycle Authority Running/Ready
with zero restarts, the credential worker Job/Pod absent, the node Ready without DiskPressure, and
48 GiB host space free.

The protected terminal advances beyond Generation 104's IAM prerequisite to
`worker-terminal-line=execution-failed/target-observation-unobservable`. The public result remains
`AwsAdminWorkerReceiptDecodeFailed`, and the supported command exits 1 after 31:01. Stable
counterexample `AWS-ADMIN-TARGET-OBSERVATION-UNOBSERVABLE-2026-08-29` licenses only diagnosis and
the narrow correction of the exact target-observation boundary that refused after successful IAM
prerequisite reconciliation. It does not license a retry, capability addition, target write,
journal reinterpretation, or inference from unobservable state.

### Target-Observation Cause Local Diagnostic Checkpoint (2026-08-29)

Source tracing proves the refusal occurs in `resolveCreatedKey`'s pre-delivery
`internalObserveCredentialTarget` call, before any Target materialization. The production client
previously converted its typed error to bounded `show` text and the execution classifier then
collapsed every outcome to one `target-observation-unobservable` token. The diagnostic correction
now classifies the complete authenticated-provider, endpoint, HTTP transport/status,
bounded-response, response-codec/status, and authored remote-refusal surface at the
Target-material client source. The direct Target Agent and retained SES custody observers lift
only those closed causes, permit substitution, generation advancement, invalid receipt projection,
and retained-custody observation failures into the worker execution algebra. HTTP status numbers,
response bodies, provider/Vault text, receipt values, and failed-delivery detail are no longer
representable at this terminal boundary. No retry, permission, capability, write, journal, or
delivery behavior changes.

The new payload-erasure regression proves distinct HTTP 403 bodies render the identical
`client/authenticated/transport/http/status/forbidden` observation cause; authored remote refusals
remain distinct and all rendered client causes are unique. The focused new case passes **1/1** and
focused Sprint-2.116 passes **9/9**. The exact AWS-admin Authority group passes **37/37**, all
**4726/4726** primary cases pass, and auxiliary admission/authentication suites pass
**27/33/31**. Repository-pinned Fourmolu is applied, HLint reports `No hints`, documentation lint
and `git diff --check` pass, and canonical warning-clean `prodbox dev check` exits 0 after 10:24.
Binary `sha256:ca6cd3af1d46a75ee6ec71ee31f57111d2247a3f5b07559ff4b8bc1b5db5a4dc`
is the qualified Generation-106 input and is byte-identical to the gate-built executable.

### Generation-106 Later-Journal Recovery Counterexample (2026-08-29)

Generation 106 builds local image
`sha256:b6c7f67e9fc54e2bc84075721a1521645b19a7335f5266e07ca3c7283ab2a76f` in 999.2 seconds,
publishes registry manifest
`sha256:e91ae3ed8a7962e596b2fc2aa595b8008e327635d7d18ceb00f83e401e325df9`, and completes the
245.4-second containerd import at OCI manifest
`sha256:f2f9499616465cf7f60e09f16d7af691913f46f5560658eb015b985b2769e932`. Baseline
reconciliation retains root session `root-session-3b9d57437d1b63cb471833be53bd9331dfa14cef89c151e67cde742140a69559`
and read-back digest `a57561193057a71d62986c9dcc39ca5d59274bd464a413ef445ed3a3b9f77df6`.
The exact-image Lifecycle Authority and Target Secret Agent are Running/Ready with zero restarts;
the Target Agent Service has its current Pod endpoint; the credential worker Job/Pod is absent;
the node is Ready; and 38 GiB remains free after exit.

Before a successor worker is created, expired-Authorized recovery refuses with
`AwsAdminCoordinatorPrepareFailed (AwsAdminProvisionerClientUnavailable
"attempt-recovery/journal-present")`. The supported command exits 1 after 30:29.89. Stable
counterexample `AWS-ADMIN-ATTEMPT-RECOVERY-JOURNAL-PRESENT-2026-08-29` establishes that
Generation 105 durably advanced beyond the sole currently recoverable
`intent-committed/initial-attempt` journal arm. It licenses only a closed payload-free refinement of
the later journal phase and read-only/source diagnosis of its exact recovery contract. It does not
license treating arbitrary presence as recoverable, creating a replacement key, clearing the
journal, inferring target state, or replaying any provider effect.

Read-only inspection of the exact-image Authority's protected log refines that refusal to
`aws-admin/recovery journal-observation=present/key-created/remint-used`. Stable refinement
`AWS-ADMIN-ATTEMPT-RECOVERY-KEY-CREATED-REMINT-USED-2026-08-29` proves the journal durably names a
created key after its single within-permit ambiguity-remint arm was consumed. Because Generation
105 stopped at the pre-delivery Target observation, the secret exists neither in a terminal Target
receipt nor in a recoverable worker. A safe continuation must preserve the predecessor journal,
run an explicitly authorized cleanup-only effect, prove stable IAM-key absence, and only then
admit a fresh bounded permit. It may not copy the key-created phase into an ordinary new journal,
interpret it as no-effect, or mint before cleanup read-back.

### Generation-91 Empty-Attach Classification (2026-08-29)

Generation 91 publishes local image
`sha256:73eabdaad0b1afff4a84509e9d04ee5ef24e39a8cd6b686fdcfc191278a9ee7d`, registry manifest
`sha256:1eed108443191b0b740c4f4ff481fd83f2126a5f23ba931aefbd764287f602c9`, and containerd OCI
manifest `sha256:83cf84add30701361298e2f52ec469745f4f1f8fd0322dec42ced1fb6407ecb4`.
The retained root session remains current, the fresh control plane reaches the recovered worker,
and the protected token is exactly
`size=empty/raw=decode-failed/terminal-ending=absent/without-terminal-ending=not-applicable` before
the unchanged public `AwsAdminWorkerReceiptDecodeFailed`. Stable counterexample
`AWS-ADMIN-WORKER-ATTACH-EMPTY-2026-08-29` therefore refines the earlier generic decode failure:
a successful attach returns no receipt bytes. The narrow correction reads the same exact
attested Pod/container through the substrate's already-declared GET-only `pods/log` capability
only for this empty-success arm, preserves the empty capture and existing refusal if that read
cannot succeed, and passes any retrieved bytes unchanged through the same classifier and canonical
decoder. It grants no general retry, normalization, or alternate receipt format.

### Empty-Attach Local Correction Checkpoint (2026-08-29)

The Kubernetes adapter now invokes one bounded exact `kubectl logs pod/<attested-name>
--container credential-provisioner` read only after an exit-zero attach produced empty stdout.
A non-empty attach never evaluates the fallback. A failed or non-zero log read returns the original
empty bytes, retaining `AwsAdminWorkerReceiptDecodeFailed`; a successful read emits a distinct
`source=pod-log` value-free classifier token and returns the unmodified capture to the same decoder.
The focused Sprint-2.116 cases pass **2/2** and the complete AWS-admin group passes **33/33**.
All **4719** primary cases and the **27/33/31** auxiliary authority suites pass;
repository-pinned Fourmolu/HLint reports `No hints`, documentation/policy and diff checks pass,
and the warning-clean all-target canonical `prodbox dev check` exits 0. Binary
`sha256:9559725e20e7f42977c72a5518e8c1047f98ea90de90c6ee0ca9688dc388e931` is the Generation-92
qualification input. Deployment validation remains outstanding.

### Generation-95 Pre-Receipt Attempts (2026-08-29)

Generation 95 publishes local image
`sha256:70db57ca673f8e464594372af12d34390be4a5ec3678e112e95bcc89e7d01836`, registry manifest
`sha256:6b64a1ddde16508df377f4b4d55af8a7481c1782aad0153569f50969ef3bef46`, and containerd OCI
manifest `sha256:24e86b070152938928276f1146fbae99d2868dad33e0c5672fd50ea488fedef5`.
Its first supported reconcile stops before AWS-admin execution when the bounded Bootstrap Broker
Deployment rollout times out. An unchanged-source retry imports the same 7.56 GB image archive and
then stops before AWS-admin execution because the registry/MinIO round-trip probe cannot connect to
`127.0.0.1:30080`. Read-only cluster observation after that exit shows RKE2 active, the node Ready,
and the node temporarily tainted `node.kubernetes.io/disk-pressure:NoSchedule` from the import,
leaving registry, MinIO, Vault, Bootstrap Broker, and Lifecycle Authority replacements Pending.
Neither attempt reaches, qualifies, or disproves the worker receipt correction. The retained node
then clears `DiskPressure` and its NoSchedule taint without manual mutation. A third same-source
attempt crosses MinIO, Vault, registry readiness, exact image import, and baseline reconciliation,
then fails before AWS-admin execution at Lifecycle Authority Helm readiness. The surviving Pod was
still annotated with Generation 94 local image `sha256:3a1f6d76…` while the moving runtime tag had
resolved to Generation 95 registry manifest `sha256:6b64a1dd…`; it crash-looped, and the supported
command completed failed-release cleanup and verified release absence. This third attempt likewise
does not qualify or disprove the receipt correction. The next same-source reconcile starts from
that exact Lifecycle Authority release absence. That clean-release retry reproduces the earlier
registry failure exactly: the unchanged 7.56 GB archive/import makes kubelet cross its 20 GiB
ephemeral-storage floor, evicts the registry, and the immediate post-import registry/MinIO probe
cannot connect. Stable counterexample `LOCAL-RUNTIME-REIMPORT-DISK-PRESSURE-2026-08-29` is owned by
this sprint's deployment-qualification surface. The narrow correction may skip archive/import only
when a closed observer proves the canonical Docker config digest for the exact runtime tag is also
the canonical config digest independently reported for that same tag by RKE2 containerd. Absent,
mismatched, failed, or malformed observations retain mandatory import. Two-sided pure tests must
hold that fail-closed boundary before the next supported crossing.

### Generation-92 Pod-Log Decode Classification (2026-08-29)

Generation 92 publishes local image
`sha256:1b07da06aa15cf193b2956e2606408e68a1ee1539e6f11cb22efa38d9fb7f9c4`, registry manifest
`sha256:5b110fee024c19ec4bc3a87782d2797b93f9777af55fe0b4a76147ece91935f9`, and containerd OCI
manifest `sha256:901b981671f6a3313331b6ef19473edfdb16fcf3097677cda3bcb24a276f412a`.
The retained root session remains current and the exact fallback executes after the empty attach.
Its protected observations are exactly
`source=attach/size=empty/raw=decode-failed/terminal-ending=absent/without-terminal-ending=not-applicable`
and
`source=pod-log/size=within-bound/raw=decode-failed/terminal-ending=lf/without-terminal-ending=decode-failed`.
The Authority performs the existing cleanup and exits through the unchanged public
`AwsAdminWorkerReceiptDecodeFailed`. Stable counterexample
`AWS-ADMIN-WORKER-POD-LOG-DECODE-2026-08-29` establishes that the fallback is non-empty but neither
raw-canonical nor made decodable by removing its one LF. It licenses no line-ending normalization
or alternate semantic receipt acceptance; the correction below instead gives the line-oriented
surface one closed canonical text envelope and extends the value-free classifier over it.

### Pod-Log Text-Envelope Local Correction Checkpoint (2026-08-29)

The worker now writes one canonical-base64 ASCII envelope around the unchanged canonical binary
receipt. The controller accepts an attach capture only when it is exactly that envelope with no
ending. The empty-attach Pod-log fallback accepts only the same canonical envelope followed by the
single LF observed in Generation 92; CRLF, no ending, repeated endings, invalid/noncanonical
base64, and an invalid inner receipt refuse. The value-free diagnostic adds raw and
once-ending-removed envelope causes without exposing bytes, counts, versions, or values. This is a
closed source-specific transport grammar, not generic trimming or an alternate semantic receipt.
Focused Sprint-2.116 passes **3/3**, the complete AWS-admin group passes **34/34**, all **4720**
primary cases and the **27/33/31** auxiliary authority suites pass; repository-pinned
Fourmolu/HLint reports `No hints`, documentation/policy and diff checks pass, and the warning-clean
all-target canonical `prodbox dev check` exits 0. Binary
`sha256:d3a908864b2d3469c3fd75a5cea946bd8ea99baf4c30f6c0cb8b62895f5860eb` is the Generation-93
qualification input. Deployment validation remains outstanding.

### Generation-93 Invalid-Envelope Classification (2026-08-29)

Generation 93 publishes local image
`sha256:81a174141d8208f003bb75361104dc3a1dc026f5687cee4b9450a6e0fe03c6b9`, registry manifest
`sha256:b0cab68c8665299b6c05e599d84da003345679e5b41c351d3b299373ffc6dff9`, and containerd OCI
manifest `sha256:a11f1fed99eaa19f2f0d7d90ed81fc178502f75ad852d217895a627799c4333c`.
The retained root session remains current and the worker is reached. Attach remains exactly empty;
the Pod-log token is exactly
`source=pod-log/size=within-bound/raw=decode-failed/raw-envelope=invalid/terminal-ending=lf/without-terminal-ending=decode-failed/without-terminal-ending-envelope=invalid`.
The Authority cleans up and returns the unchanged public `AwsAdminWorkerReceiptDecodeFailed`.
Stable counterexample `AWS-ADMIN-WORKER-POD-LOG-ENVELOPE-INVALID-2026-08-29` proves that the
canonical-base64 payload is not isolated as the once-LF-stripped capture. It does not license
substring or line selection. The next diagnostic classifies only single/multiple line topology and
zero/unique/ambiguous canonical-envelope lines without exposing bytes, lines, counts, or values.

### Invalid-Envelope Line-Topology Local Checkpoint (2026-08-29)

The protected classifier now additionally reports only `line-topology=empty|single|multiple` and
`receipt-envelope-lines=none|unique|ambiguous`. A receipt-envelope line qualifies only when both
its canonical-base64 envelope and its unchanged canonical inner receipt decode; arbitrary valid
base64 does not qualify. The classifier returns no bytes and selects no line. Its table covers
empty, single invalid, single exact envelope, multiple with one exact envelope, and multiple with
ambiguous exact envelopes. Focused Sprint-2.116 remains **3/3** and the complete AWS-admin group
remains **34/34**. All **4720** primary cases and the **27/33/31** auxiliary authority suites pass;
repository-pinned Fourmolu/HLint reports `No hints`, documentation/policy and diff checks pass,
and the warning-clean all-target canonical `prodbox dev check` exits 0. Binary
`sha256:43906c70c9bffd9eed4a21c827ca0e323e6013e033fec0fde7caf766307e991e` is the Generation-94
diagnostic input. Deployment validation remains outstanding.

### Generation-126 Target-Delivery Live Proof and Sprint Closure (2026-08-30)

The supported reconcile starts after explicit 14:23:05 EDT admission. It builds local image
`sha256:0ae58422f3fcf629788c9d20471ea2e80fac3afabe43a43288cf3ef5a61fa2d1` in 989.2
seconds, publishes registry manifest
`sha256:63e529a2935049cef138ab47fe6c798ec40acce246675f0d9da4b98398b9097e`, imports OCI
manifest `sha256:74a390fbd0b0d456c5b131e7eb74666e00749384a930aa4855762030549831e9`
in 128.0 seconds, and deletes only Generation 125's superseded local image
`sha256:105f2e58e416be51f74edaa92a797360026e88d424ed0c226a7e3007bda98806`.
Retained root session `root-session-9c54db6a…` and digest `a5756119…` remain exact.

The Target Agent rolls at 14:46:26/14:46:28 EDT. The credential worker starts at 14:47:14; the
Target worker is created at 14:47:25 and starts at 14:47:26. It is cleaned at 14:47:31, followed by
the credential worker at 14:47:34. Its final protected observation is
`source=attach/size=within-bound/raw=decode-failed/raw-envelope=invalid/terminal-ending=absent/without-terminal-ending=not-applicable/without-terminal-ending-envelope=not-applicable/line-topology=multiple/receipt-envelope-lines=unique/receipt-prefix-lines=unique/worker-terminal-line=none`.
The run advances through Target delivery and therefore live-proves the shared runtime-manifest
parser and every Sprint-2.116 receipt-transport correction.

The later distinct terminal is
`AuthorityBackupGenesisCopyFailed "AuthorityBackupExportResponseInvalid ControlPlaneRequestInvalid"`.
Register stable counterexample `AUTHORITY-BACKUP-EXPORT-200-RESPONSE-INVALID-2026-08-30` under
Sprint `2.117`; it is not a Sprint-2.116 receipt failure. Postflight proves no credential/Target
one-shot residue, NetworkPolicy generation 48 with exact `192.168.2.46/32:6443`, exact-image Ready
Target Agent generation 71 and Lifecycle Authority generation 13, a Ready pressure/taint-free
node, and 42 GiB free. The conservative retained-attempt fence runs through 15:17:55 EDT; no
Generation 127 command may start before 15:17:56.

### Validation

1. The diagnostic has a finite exhaustive vocabulary and cannot carry receipt bytes or values.
2. Focused tests, the complete local suite, documentation/diff checks, and canonical `dev check`
   pass before deployment.
3. A supported reconcile identifies and crosses
   `AWS-ADMIN-WORKER-RECEIPT-DECODE-2026-08-29`; any later distinct refusal is registered first.

### Remaining Work

None.

## Sprint 2.117: Classify Authority Backup Export 200 Response [✅ Done]

**Status**: Done — Generation 127 identifies the endpoint-success wrapper and Generation 128
crosses the corrected direct-success export and backup-copy path.
**Implementation**: `src/Prodbox/ControlPlane/AuthorityBackupExportClient.hs`,
`src/Prodbox/ControlPlane/AuthorityBackupExportEndpoint.hs`, and focused validation under
`test/unit/ControlPlaneAuthorityBackupEndpoint.hs`.
**Deployment qualification**: proven — Generation 128 crosses the exact Generation-126 response
boundary and resumes retained first-reconcile credential provisioning.
**Independent Validation**: a pure closed classifier over bounded response bytes and the existing
canonical codecs proves exhaustive, value-free response-shape tokens without Kubernetes, Vault,
MinIO, AWS, or retained aggregate material.
**Docs to update**: `documents/engineering/lifecycle_control_plane_architecture.md`,
`documents/engineering/lifecycle_reconciliation_doctrine.md`, `DEVELOPMENT_PLAN/README.md`, and
`DEVELOPMENT_PLAN/00-overview.md`.

### Objective

Identify why the authenticated Authority Backup export route returns HTTP 200 bytes that its
canonical client rejects as `ControlPlaneRequestInvalid`, without rendering response bytes,
aggregate material, digests, sizes, request identities, or transport detail and without accepting
an alternate response representation before live evidence licenses it.

### Deliverables

- Add one finite value-free classifier at the export client boundary that distinguishes canonical
  export response, endpoint-result envelope, aggregate envelope, empty/malformed response, and
  only other closed source-derived shapes needed to identify the wire mismatch.
- Preserve the existing authenticated route, replay protection, HTTP status handling, canonical
  request/response bounds, digest validation, backup copy, and admission state machine.
- Add exhaustive two-sided tests proving unique tokens and collapse of distinct private response
  values to the same token.
- Deploy the diagnostic after the active fence, register its exact result, and correct only the
  live-proven response shape.

### Validation

1. The diagnostic vocabulary is finite and cannot carry response bytes, aggregate material,
   digests, sizes, identities, or private error detail.
2. Focused endpoint/client tests, the complete local suite, documentation/diff checks, and
   canonical `prodbox dev check` pass before deployment.
3. A supported reconcile identifies and crosses
   `AUTHORITY-BACKUP-EXPORT-200-RESPONSE-INVALID-2026-08-30`; any later distinct refusal is
   registered first.

### Response-Shape Diagnostic Local Checkpoint (2026-08-30)

Source tracing proves the route canonically encodes
`Either Text AuthorityBackupExportResponse`, while the client attempts to decode
`AuthorityBackupExportResponse` directly. The new behavior-neutral classifier recognizes only
direct response, endpoint success, endpoint failure, empty, or other. It discards both success and
failure payloads; two distinct private values on each endpoint-result arm collapse to the same
token, all five tokens are unique, and the client still rejects every non-direct body. The complete
Authority Backup endpoint group passes **18/18**, primary **4738/4738**, and auxiliary suites
**27/33/31**. Repository policy, Fourmolu, HLint (`No hints`), warning-clean all-target compilation,
documentation, and diff gates pass; canonical `prodbox dev check` exits 0. Its gate-built and
installed executable is byte-identical at
`sha256:f6b8abba0b1afccb27dc5b4781c47214db0833116cb0e276513ef72048b82cf5`. Live deployment
remains outstanding after the Generation-126 fence.

### Generation-127 Endpoint-Success Live Classification (2026-08-30)

Generation 127 starts after explicit 15:18:02 EDT admission. It builds local image
`sha256:7ea3130e9a305d39f4d72da6e669677d2480bcb78cdfea27826651cd9ea21d09` in 991.1
seconds, publishes registry manifest
`sha256:7bccc219b8f786de93171ff56673df7e56f206f954f86aebc5f5dcde131e4a88`, and imports OCI
manifest `sha256:37e0e3ee45c5622d8e11c2cfd4f497715c4221685409a260e3c58d176e893c4d` in
135.5 seconds. It deletes only Generation 126's superseded local image
`sha256:0ae58422f3fcf629788c9d20471ea2e80fac3afabe43a43288cf3ef5a61fa2d1`. Retained root
session `root-session-9c54db6a…` and digest `a5756119…` remain exact.

The Target Agent starts on the exact image at 15:41:55 EDT and the Lifecycle Authority at
15:42:26. Retained admission resumes directly at backup export without creating a credential or
Target worker. The exact terminal is
`AuthorityBackupExportResponseInvalid ControlPlaneRequestInvalid AuthorityBackupExportResponseEndpointSuccess`.
This closes stable counterexample `AUTHORITY-BACKUP-EXPORT-200-RESPONSE-INVALID-2026-08-30` to the
endpoint's canonical success-wrapper shape and licenses only direct canonical success encoding,
matching every peer response endpoint. Non-200 cases retain bounded plain summary bodies; the
client, authentication, replay, request, digest, copy, and admission paths do not change.

Postflight proves no credential/Target one-shot residue, NetworkPolicy generation 49 with exact
`192.168.2.46/32:6443`, exact-image Ready Target Agent generation 72 and Lifecycle Authority
generation 14, a Ready pressure/taint-free node, and 38 GiB free. Because this run creates no new
credential-worker attempt or permit, it introduces no successor worker fence.

### Direct Success-Response Correction Local Checkpoint (2026-08-30)

The export endpoint now writes `AuthorityBackupExportResponse` directly under the canonical
bounded response envelope on HTTP 200 and writes only its existing closed plain summary for each
non-200 result. The client remains unchanged and therefore still validates canonical framing,
envelope size, and digest equality before returning aggregate bytes. A focused regression decodes
the production success body as the direct response and pins the conflict body to its closed
summary. The complete Authority Backup group passes **18/18**, primary **4738/4738**, and
auxiliary suites **27/33/31**. Repository policy, Fourmolu, HLint (`No hints`), warning-clean
all-target compilation, documentation, and diff gates pass; canonical `prodbox dev check` exits 0.
Its gate-built and installed executable is byte-identical at
`sha256:753f18a42af42abac3b73cd4cb6c2e2ef7ac24e4d0fba1fa9b9670f86fb03642`.

### Generation-128 Direct-Success Live Proof (2026-08-30)

Generation 128 starts after explicit 15:58:31 EDT admission. It builds local image
`sha256:54c4fdddc8a90cbc07ede062faf86d62519898e9f2d2faad12bb3a6ae865fa3c` in 1001.8
seconds, publishes registry manifest
`sha256:04245737a22229a1dc57082576a26c6d6b66c5229f05cc84b968aab7ee780c9d`, and imports OCI
manifest `sha256:89653645fdbd3eb08ac0da46e70bf835be6a0e6e131a0dde9eca3e539746f587` in
147.0 seconds. It removes only Generation 127's superseded local image and untagged registry
manifest. Retained root identity remains exact.

Exact-image Target Agent generation 73 and Lifecycle Authority generation 15 start at 16:23:40
and 16:24:07 EDT. Authority Backup export and copy succeed, positively proving the direct-success
correction and closing stable counterexample
`AUTHORITY-BACKUP-EXPORT-200-RESPONSE-INVALID-2026-08-30`. Retained first-reconcile continuation
then creates credential worker `credential-provisioner-first-reconcile-d142c8895122fdc2` at
16:24:28; its container starts at 16:24:29 and is killed at 16:24:36. The exact worker terminal is
`execution-failed/iam-prerequisite-failed/aws/create-lifecycle-role/service/other-client`, a later
distinct refusal registered under Sprint `2.118`.

Postflight at 16:25:02 proves no credential/Target one-shot residue, NetworkPolicy generation 50
with exact `192.168.2.46/32:6443`, both retained workloads Ready on the exact image, a Ready
pressure/taint-free node, and 38 GiB free. The conservative retained-attempt fence runs through
16:54:56 EDT; no Generation 129 command may start before 16:54:57.

### Remaining Work

None.

## Sprint 2.118: Classify Lifecycle-Provider CreateRole Service Fault [✅ Done]

**Status**: Done — the finite documented client-fault vocabulary is complete and Generation 129
crosses the earlier `service/other-client` condition to role read-back.
**Implementation**: `src/Prodbox/Lifecycle/CredentialProvisioner/ProductionIam.hs` and focused
validation under `test/unit/CredentialProvisionerAwsAdminAuthority.hs`.
**Deployment qualification**: proven — Generation 129 crosses the exact Generation-128 IAM
boundary and reaches a later distinct role read-back refusal.
**Independent Validation**: a pure closed classifier over structured AWS service faults proves
exhaustive, value-free cause tokens without AWS, Kubernetes, Vault, MinIO, retained aggregate
material, or private provider detail.
**Docs to update**: `documents/engineering/lifecycle_control_plane_architecture.md`,
`documents/engineering/lifecycle_reconciliation_doctrine.md`, `DEVELOPMENT_PLAN/README.md`, and
`DEVELOPMENT_PLAN/00-overview.md`.

### Objective

Identify the exact documented client-side IAM service fault returned by lifecycle-provider role
creation without rendering provider messages, request identifiers, response bodies, credentials,
account identity, role policy material, or transport detail and without changing the IAM request,
retry, receipt, cleanup, or admission behavior before live evidence licenses it.

### Deliverables

- Refine the finite AWS service-fault vocabulary with only the documented closed client-side
  `CreateRole` faults that currently collapse into `service/other-client`.
- Preserve request construction, signing, transport, retry, role/policy semantics, receipt
  encoding, cleanup, and first-reconcile admission behavior.
- Add exhaustive token and private-detail-collapse tests for every added cause while retaining the
  closed `other-client` fallback.
- Deploy the diagnostic after the active fence, register its exact result, and correct only the
  live-proven fault.

### Validation

1. The diagnostic vocabulary is finite and cannot carry AWS messages, request identifiers,
   response bodies, credentials, account identity, role/policy material, or private detail.
2. Focused AWS-admin Authority tests, the complete local suite, documentation/diff checks, and
   canonical `prodbox dev check` pass before deployment.
3. A supported reconcile identifies and crosses
   `AWS-ADMIN-CREATE-LIFECYCLE-ROLE-OTHER-CLIENT-2026-08-30`; any later distinct refusal is
   registered first.

### CreateRole Service-Fault Diagnostic Local Checkpoint (2026-08-30)

The finite AWS service classifier now identifies exactly the documented `CreateRole` client-side
faults that formerly reached `other-client`: concurrent modification, invalid input, limit
exceeded, and malformed policy document. The existing entity-already-exists class is unchanged,
the documented service failure retains its generic 5xx/server class, and unknown 4xx codes retain
the explicit fallback. A focused table proves the four exact tokens and that distinct provider
messages and request identifiers collapse to the same cause. No request construction, signing,
transport, retry, role/policy semantics, receipt, cleanup, or admission behavior changes.

Focused Sprint-2.118 and pre-existing exhaustive tests pass **1/1** each, primary **4739/4739**,
and auxiliary authority suites **27/33/31**. Repository policy, Fourmolu, HLint (`No hints`),
warning-clean all-target compilation, documentation, and diff gates pass; canonical `prodbox dev
check` exits 0. Its gate-built and installed executable is byte-identical at
`sha256:e3f64647ed48d473136cef4266e41a13ce0feed307bf5fabe3d5288ad9e1cbb6`.

### Generation-129 CreateRole Boundary Live Proof (2026-08-30)

Generation 129 starts after explicit 16:55:06 EDT admission. It builds local image
`sha256:7fa9bcc2cf7c0cb9465c45fff6d4a17ede18cedd5b4a55e425a84d4fbf524ddf` in 994.1
seconds, publishes registry manifest
`sha256:a76d401ad379176806075704c5872c59c55e734e8ec5a1b88a90d34a20edb7b2`, and imports OCI
manifest `sha256:c5a8fe6f21587e4ff6557e21b22a7c02d7fda9b23e45fba489893fb4415ce943` in
148.5 seconds. It removes only Generation 128's superseded local image and untagged registry
manifest. Retained root identity remains exact.

Exact-image Target Agent generation 74 and Lifecycle Authority generation 16 start at 17:19:38
and 17:20:06 EDT. The former `create-lifecycle-role/service/other-client` condition does not recur;
execution crosses the Generation-128 boundary and reaches
`execution-failed/iam-prerequisite-failed/role-read-back-mismatch`. This closes Sprint `2.118` on
its finite classifier and registers the later distinct stable counterexample
`AWS-ADMIN-LIFECYCLE-ROLE-READ-BACK-MISMATCH-2026-08-30` under Sprint `2.119` before behavior
changes. The credential worker is created at 17:20:26, starts at 17:20:27, and is killed at
17:20:33.

Postflight at 17:20:54 proves no credential/Target one-shot residue, NetworkPolicy generation 51
with exact `192.168.2.46/32:6443`, both retained workloads Ready on the exact image, a Ready
pressure/taint-free node, and 42 GiB free. The conservative retained-attempt fence runs through
17:50:53 EDT; no Generation 130 command may start before 17:50:54.

### Remaining Work

None.

## Sprint 2.119: Classify Lifecycle-Provider Role Read-Back Mismatch [✅ Done]

**Status**: Done — Generation 130 identifies the exact trust-policy mismatch arm.
**Implementation**: `src/Prodbox/Lifecycle/CredentialProvisioner/ProductionIam.hs` and focused
validation under `test/unit/CredentialProvisionerAwsAdminAuthority.hs`.
**Deployment qualification**: proven — Generation 130 emits the exact nested trust-policy cause.
**Independent Validation**: a pure closed projection over the four source-authored read-back
outcomes proves unique value-free cause tokens without AWS, Kubernetes, Vault, MinIO, retained
aggregate material, or private provider detail.
**Docs to update**: `documents/engineering/lifecycle_control_plane_architecture.md`,
`documents/engineering/lifecycle_reconciliation_doctrine.md`, `DEVELOPMENT_PLAN/README.md`, and
`DEVELOPMENT_PLAN/00-overview.md`.

### Objective

Identify whether Lifecycle-provider role read-back observes absence, name mismatch, ARN mismatch,
or trust-policy mismatch without rendering observed names, ARNs, policy material, provider output,
account identity, or request detail and without changing role creation, reconciliation, comparison,
retry, receipt, cleanup, or admission behavior before live evidence licenses it.

### Deliverables

- Replace the private free-text role read-back mismatch payload with one closed four-constructor
  cause and project each constructor to a unique stable token.
- Preserve role creation/update/read-back order, exact name/ARN/policy comparison, request signing,
  retry, receipt, cleanup, and first-reconcile admission behavior.
- Add an exhaustive token table proving uniqueness and unrepresentability of observed role values.
- Deploy the diagnostic after the active fence, register its exact result, and correct only the
  live-proven mismatch.

### Validation

1. The diagnostic vocabulary is finite and cannot carry observed names, ARNs, policy material,
   provider output, account identity, or request detail.
2. Focused AWS-admin Authority tests, the complete local suite, documentation/diff checks, and
   canonical `prodbox dev check` pass before deployment.
3. A supported reconcile identifies and crosses
   `AWS-ADMIN-LIFECYCLE-ROLE-READ-BACK-MISMATCH-2026-08-30`; any later distinct refusal is
   registered first.

### Role Read-Back Cause Diagnostic Local Checkpoint (2026-08-30)

The production mismatch no longer contains private free text. Its closed four-constructor cause
names only role absence, name mismatch, ARN mismatch, or trust-policy mismatch, and its terminal
projection adds the unique stable tokens `absent`, `name-mismatch`, `arn-mismatch`, and
`trust-policy-mismatch`. Observed role names, ARNs, and policy bytes are unrepresentable. Role
creation, update, read-back order, exact name/ARN/policy comparison, request signing, retry,
receipt, cleanup, and admission behavior remain unchanged.

Focused Sprint-2.119 passes **1/1**, primary **4740/4740**, and auxiliary authority suites
**27/33/31**. Repository policy, Fourmolu, HLint (`No hints`), warning-clean all-target compilation,
documentation, and diff gates pass; canonical `prodbox dev check` exits 0. Its gate-built and
installed executable is byte-identical at
`sha256:beb4342f6c5ef4118225d7dc864e2e3033d597a7a195ea49dc02ebef52c67360`.

### Generation-130 Trust-Policy Mismatch Live Classification (2026-08-30)

Generation 130 starts after explicit 17:51:02 EDT admission. It builds local image
`sha256:dd5128d60b61978491fff8c41e6f4d4e9cb865aaac29f2607e0ded32990c3bef` in 989.1
seconds, publishes registry manifest
`sha256:6b81ecf2a4ff5205bf905d83086a3f517dd54623ce95d138db784c3f9eb167dc`, and imports OCI
manifest `sha256:d135c437a544062b97b48e69173775571c6521a8cbd6d9bea55c4c76c9246179` in
141.7 seconds. It removes only Generation 129's superseded local image and untagged registry
manifest. Retained root identity remains exact.

Exact-image Target Agent generation 75 and Lifecycle Authority generation 17 start at 18:15:09
and 18:15:36 EDT. The credential worker is created at 18:15:56, starts at 18:15:57, and is killed
at 18:16:03. Its exact terminal is
`execution-failed/iam-prerequisite-failed/role-read-back-mismatch/trust-policy-mismatch`, positively
closing Sprint `2.119` and registering the narrower stable counterexample
`AWS-ADMIN-LIFECYCLE-ROLE-TRUST-POLICY-SHAPE-2026-08-30` under Sprint `2.120` before policy
comparison behavior changes.

Postflight at 18:16:19 proves no credential/Target one-shot residue, NetworkPolicy generation 52
with exact `192.168.2.46/32:6443`, both retained workloads Ready on the exact image, a Ready
pressure/taint-free node, and 42 GiB free. The conservative retained-attempt fence runs through
18:46:23 EDT; no Generation 131 command may start before 18:46:24.

### Remaining Work

None.

## Sprint 2.120: Classify AWS Trust-Policy Representation Shape [✅ Done]

**Status**: Done — Generation 131 identifies the returned policy as IAM singleton-equivalent.
**Implementation**: `src/Prodbox/Lifecycle/CredentialProvisioner/ProductionIam.hs` and focused
validation under `test/unit/CredentialProvisionerAwsAdminAuthority.hs`.
**Deployment qualification**: proven — Generation 131 emits the exact singleton-equivalent token.
**Independent Validation**: a pure closed classifier over decoded policy values proves its tokens
and private-value collapse without AWS, Kubernetes, Vault, MinIO, retained aggregate material, or
provider response detail.
**Docs to update**: `documents/engineering/lifecycle_control_plane_architecture.md`,
`documents/engineering/lifecycle_reconciliation_doctrine.md`, `DEVELOPMENT_PLAN/README.md`, and
`DEVELOPMENT_PLAN/00-overview.md`.

### Objective

Determine whether AWS's returned trust policy is invalid, semantically identical after only the
IAM grammar's singleton object/string versus list normalization, or otherwise different without
rendering either policy, principal, action, account identity, or provider detail and without
accepting the representation before live evidence licenses it.

### Deliverables

- Add one closed mismatch classifier with only `invalid`, `iam-singleton-equivalent`, and `other`
  causes below the existing trust-policy mismatch arm.
- Normalize only the IAM grammar's `Statement`, `Action`, and `Principal.AWS` singleton forms for
  diagnostic comparison; retain the current exact acceptance comparison.
- Add exhaustive token, semantic counterexample, and distinct-private-policy collapse tests.
- Deploy the diagnostic after the active fence, register its exact result, and correct only the
  live-proven representation class.

### Validation

1. The classifier cannot carry policy bytes, principals, actions, account identity, or provider
   detail and does not widen accepted policy semantics.
2. Focused AWS-admin Authority tests, the complete local suite, documentation/diff checks, and
   canonical `prodbox dev check` pass before deployment.
3. A supported reconcile identifies and crosses
   `AWS-ADMIN-LIFECYCLE-ROLE-TRUST-POLICY-SHAPE-2026-08-30`; any later distinct refusal is
   registered first.

### Trust-Policy Shape Diagnostic Local Checkpoint (2026-08-30)

The trust-policy mismatch arm now classifies only invalid JSON, semantic equality after IAM's
documented singleton `Statement`, `Action`, and `Principal.AWS` object/string-versus-list forms, or
other difference. The production acceptance comparator remains exact, so no representation is yet
admitted. The three tokens are unique; two structurally equivalent policies with different private
Sids, account IDs, users, and principals collapse to the same singleton-equivalent cause, while an
action substitution remains `other`.

Focused Sprint-2.120 passes **1/1**, primary **4741/4741**, and auxiliary authority suites
**27/33/31**. Repository policy, Fourmolu, HLint (`No hints`), warning-clean all-target compilation,
documentation, and diff gates pass; canonical `prodbox dev check` exits 0. Its gate-built and
installed executable is byte-identical at
`sha256:5f88e3358f94394dcad185c864f0f8f3d56827f4539fd1e7a6a7e2fdede38d26`.

### Generation-131 IAM-Singleton Live Classification (2026-08-30)

Generation 131 starts after explicit 18:46:33 EDT admission. It builds local image
`sha256:216a433bcfe27be110d92ae5f2e55972e41196a455366a965d4b278c3f4b8f8c` in 986.5
seconds, publishes registry manifest
`sha256:88ff9d5a71f40ca31b639338af59525e5f9480c417a6e65cea4063c9def578ba`, and imports OCI
manifest `sha256:e61860c9647e43f6513b7b90b0f415de2dc3d3494a12a342c36e3dc4af92dcb3` in
140.7 seconds. It removes only Generation 130's superseded local image and untagged registry
manifest. Retained root identity remains exact.

Exact-image Target Agent generation 76 and Lifecycle Authority generation 18 start at 19:10:44
and 19:11:11 EDT. The credential worker is created and starts at 19:11:32, then is killed at
19:11:38. Its exact terminal is
`execution-failed/iam-prerequisite-failed/role-read-back-mismatch/trust-policy-mismatch/iam-singleton-equivalent`.
This closes stable counterexample `AWS-ADMIN-LIFECYCLE-ROLE-TRUST-POLICY-SHAPE-2026-08-30` to the
documented singleton representation and licenses only that semantic comparison under Sprint
`2.121`.

Postflight at 19:11:53 proves no credential/Target one-shot residue, NetworkPolicy generation 53
with exact `192.168.2.46/32:6443`, both retained workloads Ready on the exact image, a Ready
pressure/taint-free node, and 42 GiB free. The conservative retained-attempt fence runs through
19:41:58 EDT; no Generation 132 command may start before 19:41:59.

### Remaining Work

None.

## Sprint 2.121: Accept Documented IAM Trust-Policy Singleton Forms [✅ Done]

**Status**: Done — Generation 132 crosses the trust-policy read-back and reaches Target
observation.
**Implementation**: `src/Prodbox/Lifecycle/CredentialProvisioner/ProductionIam.hs` and focused
validation under `test/unit/CredentialProvisioner.hs` and
`test/unit/CredentialProvisionerAwsAdminAuthority.hs`.
**Deployment qualification**: proven — Generation 132 crosses the exact Generation-131 boundary.
**Independent Validation**: pure policy equality cases and an injected native-IAM role
reconciliation prove the accepted representation without AWS, Kubernetes, Vault, MinIO, retained
aggregate material, or provider response detail.
**Docs to update**: `documents/engineering/lifecycle_control_plane_architecture.md`,
`documents/engineering/lifecycle_reconciliation_doctrine.md`, `DEVELOPMENT_PLAN/README.md`, and
`DEVELOPMENT_PLAN/00-overview.md`.

### Objective

Accept an AWS-returned Lifecycle-provider trust policy only when it is exactly equal to the authored
policy or becomes equal after normalizing the documented singleton forms for `Statement`, `Action`,
and `Principal.AWS`; reject invalid JSON and every other semantic difference.

### Deliverables

- Introduce a trust-policy-specific equality predicate that admits exact equality or the already
  live-proven IAM-singleton-equivalent class.
- Keep user and role permissions-policy comparison unchanged and retain exact action/principal,
  statement, Sid, effect, version, and all unrecognized-field equality after normalization.
- Add positive single/mixed-normalization cases and negative action, principal, statement, version,
  and extra-field counterexamples through both the pure predicate and native IAM seam.
- Deploy after the active fence and register the next distinct terminal before any further behavior
  change.

### Validation

1. Only the three documented singleton representation forms widen equality; invalid and other
   differences remain refused.
2. Focused credential tests, the complete local suite, documentation/diff checks, and canonical
   `prodbox dev check` pass before deployment.
3. A supported reconcile crosses
   `AWS-ADMIN-LIFECYCLE-ROLE-TRUST-POLICY-SHAPE-2026-08-30`; any later distinct refusal is
   registered first.

### Trust-Policy Singleton Acceptance Local Checkpoint (2026-08-30)

Role trust-policy read-back now uses a dedicated comparator that admits exact decoded equality or
equality after only the live-proven `Statement`, `Action`, and `Principal.AWS` singleton
normalizations. User and role inline permissions-policy comparison still uses exact decoded
equality. Pure cases accept each singleton form separately and together, and refuse invalid JSON,
changed actions, principals, statement sets, versions, and unrecognized fields. The injected
native IAM seam accepts the singleton action representation and refuses a changed action with the
closed `trust-policy-mismatch/other` cause.

Focused Sprint-2.121 passes **2/2**, primary **4743/4743**, and auxiliary authority suites
**27/33/31**. Repository policy, Fourmolu, HLint (`No hints`), warning-clean all-target compilation,
documentation, and diff gates pass; canonical `prodbox dev check` exits 0. Its gate-built and
installed executable is byte-identical at
`sha256:008e2e6f7c0dd4ed1109f59105fec0c2d42561a4967da5ec6a4409f8bf771369`.

### Generation-132 Trust-Policy Acceptance Live Proof (2026-08-30)

Generation 132 starts after explicit 19:42:04 EDT admission. It builds local image
`sha256:6aa223b3241972e19e008902a2843baf6df21ae858646893800af606aa3281a4` in 985.2
seconds, publishes registry manifest
`sha256:2cb0d1c30c56452d3dc064960a1fb56567451d342643b1e50f26cf890c7d96f9`, and imports OCI
manifest `sha256:d73d4bff2c8f199229d0ca8512a81e7e5257a7327b075f05d8eb347ef630e059` in
151.4 seconds. It removes only Generation 131's superseded local image and untagged registry
manifest. Retained root session and digest remain exact.

Exact-image Target Agent generation 77 and Lifecycle Authority generation 19 start at 20:06:13
and 20:06:39 EDT. A resumed credential worker starts at 20:06:59 and creates a Target worker at
20:07:08; the Target container starts at 20:07:09, and the owning credential worker is killed at
20:07:17. A successor credential worker starts at 20:07:21 and is killed at 20:07:30. Its exact
terminal is `execution-failed/target-observation-unobservable/client/response-codec/invalid`.
This positively crosses the former trust-policy mismatch, closes Sprint `2.121`, and registers
stable counterexample `TARGET-MATERIAL-RESPONSE-CODEC-INVALID-2026-08-30` under Sprint `2.122`
before Target observation behavior changes.

Postflight at 20:07:52 proves no credential or Target one-shot residue, NetworkPolicy generation
54 with exact `192.168.2.46/32:6443`, both retained workloads Ready on the exact image, a Ready
pressure/taint-free node, and 42 GiB free. The conservative retained-attempt fence runs through
20:37:50 EDT; no Generation 133 command may start before 20:37:51.

### Remaining Work

None.

## Sprint 2.122: Classify Codec-Invalid Target-Observation HTTP Status [✅ Done]

**Status**: Done — the codec-invalid Target-material cause carries only its closed HTTP-status
class, and Generation 134 emits the exact `status/server` token.
**Implementation**: `src/Prodbox/ControlPlane/TargetMaterialClient.hs` and focused validation
under `test/unit/CredentialProvisionerAwsAdminAuthority.hs`.
**Live-proof**: proven — Generation 134 emits the exact `response-codec/invalid/status/server`
classification.
**Deployment qualification**: pending — Generation 134 exposes the separate server-response shape
registered under Sprint `2.124`; no current-revision aggregate claim is made.
**Independent Validation**: a pure closed status classifier and injected Target-material client
responses prove the diagnostic without AWS, Kubernetes, Vault, MinIO, retained aggregate
material, response bodies, or provider detail.
**Docs to update**: `documents/engineering/lifecycle_control_plane_architecture.md`,
`documents/engineering/lifecycle_reconciliation_doctrine.md`, `DEVELOPMENT_PLAN/README.md`, and
`DEVELOPMENT_PLAN/00-overview.md`.

### Objective

Determine which bounded HTTP status class accompanies the Target-material response body that fails
canonical decoding, without retaining or rendering the body and without changing request,
authentication, replay, decoding, observation, retry, cleanup, receipt, or admission behavior.

### Deliverables

- Refine only the codec-invalid Target-material client cause with the existing closed HTTP status
  vocabulary.
- Keep decoded response-status causes and every transport, codec, and remote-refusal cause
  distinct; preserve the original response body as unrepresentable at the diagnostic boundary.
- Add exhaustive unique-token, status-boundary, private-body-collapse, and production client-seam
  tests.
- Deploy after the active fence, register the exact status class, and correct only the live-proven
  response boundary.

### Validation

1. Every integer HTTP status maps to one closed value-free class and response bytes cannot affect
   that class.
2. Focused Target-material/AWS-admin tests, the complete local suite, documentation/diff checks,
   and canonical `prodbox dev check` pass before deployment.
3. A supported reconcile identifies and crosses
   `TARGET-MATERIAL-RESPONSE-CODEC-INVALID-2026-08-30`; any later distinct refusal is registered
   first.

### Target-Material Codec-Invalid Status Local Checkpoint (2026-08-30)

The Target-material production response seam now preserves the HTTP status attached to a
canonically invalid response only through the existing closed status vocabulary. The raw response
body and numeric status are unrepresentable in the cause. Exact 400, 401, 403, 404, 409, and 429
statuses, the remaining 4xx class, the 5xx class, and all other integers have explicit cases;
distinct private bodies at one status collapse to the same token. The pre-existing generic codec
cause remains available to other clients, and request, authentication, replay, decoding,
observation, retry, cleanup, receipt, and admission behavior are unchanged.

Focused Sprint-2.122 and the pre-existing exhaustive Target-observation case pass **1/1** each,
primary **4744/4744**, and auxiliary authority suites **27/33/31**. Repository policy, Fourmolu,
HLint (`No hints`), warning-clean all-target compilation, documentation, and diff gates pass;
canonical `prodbox dev check` exits 0. Its gate-built and installed executable is byte-identical at
`sha256:679f2ef80e2b18907dd6d99e2b7b5e1c1c2b40f3dfbe58e158d3545d3f911010`.

### Remaining Work

None.

### Generation-133 Earlier Heartbeat Boundary (2026-08-30)

Generation 133 starts after explicit 20:37:59 EDT admission and a final 20:38:12 preflight. It
builds local image `sha256:255d7693415ecfe268fb402db2984fd7a2c5aaf65f781b88657a200b40c0e3c4`,
publishes registry manifest
`sha256:ca4aac58ddb374f32008c0678ef43b8518916a92e8329eb924ed2b83698efb88`, and imports OCI
manifest `sha256:c0ef0c55b21466cfa90a4f78a6c76c473476ec533c08579aeee1e33cd79e8bc3` in
123.7 seconds. It removes only Generation 132's superseded local image and untagged registry
manifest. Retained root session and digest remain exact.

Exact-image Target Agent generation 78 and Lifecycle Authority generation 20 start at 21:02:10
and 21:02:37 EDT. The first credential worker starts at 21:02:56 and creates a Target worker that
starts at 21:03:08. A later credential worker starts at 21:03:21 and is killed at 21:03:23. The
exact terminal is `AwsAdminCoordinatorAttestFailed (AwsAdminProvisionerClientRefused
"pod-heartbeat-stale")`; its receipt-transport diagnostic records no terminal worker ending, so
this run cannot yet classify the earlier Target response. Source closure proves that
`requireEstablishedAuthorityBackupAdmission` samples one heartbeat before retained continuation,
while `productionAwsAdminKubernetesBoundary` captures and reuses it for every later Job. Register
stable counterexample `AWS-ADMIN-SUCCESSOR-JOB-HEARTBEAT-STALE-2026-08-30` under Sprint `2.123`.

Postflight at 21:03:41 proves no credential or Target one-shot residue, the exact Lifecycle
Authority NetworkPolicy projection, both retained workloads Ready on the exact image, a Ready
pressure/taint-free node, and 41 GiB free. The conservative retained-attempt fence runs through
21:33:43 EDT; no Generation 134 command may start before 21:33:44.

## Sprint 2.123: Refresh the AWS-Admin Job Heartbeat Per Attempt [✅ Done]

**Status**: Done — each Job attempt now samples one fresh heartbeat, and Generation 134's successor
crosses the former `pod-heartbeat-stale` attestation refusal.
**Implementation**: `src/Prodbox/Lifecycle/CredentialProvisioner/AwsAdminCoordinator.hs`,
`src/Prodbox/Lifecycle/CredentialProvisioner/AwsAdminKubernetes.hs`, and
`src/Prodbox/CLI/Rke2.hs`, with focused validation under
`test/unit/CredentialProvisionerAwsAdminAuthority.hs`.
**Live-proof**: proven — Generation 134 creates and attests the fresh-heartbeat successor Job and
reaches the later Target response boundary.
**Deployment qualification**: pending — Generation 134 exposes the separate server-response shape
registered under Sprint `2.124`; no current-revision aggregate claim is made.
**Independent Validation**: an injected Job-heartbeat source and sequential coordinator attempts
prove that each attempt samples a fresh value while create, observation, attestation, and cleanup
share that attempt's one exact heartbeat, without AWS, Kubernetes, Vault, MinIO, or Target material.
**Docs to update**: `documents/engineering/lifecycle_control_plane_architecture.md`,
`documents/engineering/lifecycle_reconciliation_doctrine.md`, `DEVELOPMENT_PLAN/README.md`, and
`DEVELOPMENT_PLAN/00-overview.md`.

### Objective

Close `AWS-ADMIN-SUCCESSOR-JOB-HEARTBEAT-STALE-2026-08-30` by sampling the host heartbeat at the
start of each AWS-admin Job attempt instead of once before the retained first-reconcile loop,
without relaxing the Authority's freshness bound or changing durable intent, permit, deadline,
attestation, worker execution, receipt, or cleanup rules.

### Deliverables

- Make heartbeat acquisition an explicit fallible effect of the AWS-admin Kubernetes boundary and
  classify acquisition failure before any Job create.
- Carry one sampled heartbeat through that attempt's exact Job render, Job/Pod observation,
  Authority attestation, and pre-delete exact-object observation; stable absence remains keyed by
  the immutable Job/Pod UID cleanup binding.
- Recover a completed permit using the heartbeat already bound into its signed Job attestation;
  never substitute a new value during cleanup.
- Add the named sequential-attempt reproducer plus clock-failure and exact cleanup-binding cases.
- Deploy only after the active retained-attempt fence and register any later distinct refusal
  before changing its behavior.

### Validation

1. The stable reproducer observes distinct fresh heartbeats for two sequential attempts separated
   beyond 30 seconds, while every effect within one attempt observes one identical value.
2. Clock failure creates no Job; completed-permit recovery cleans with the signed heartbeat; stale,
   future, deadline, attestation, and cleanup refusal tests remain unchanged.
3. Focused AWS-admin coordinator tests, the complete local suite, documentation/diff checks, and
   canonical `prodbox dev check` pass before deployment.
4. Generation 134 crosses the stale-successor boundary; any later distinct refusal is registered
   first.

### Remaining Work

None.

### Per-Attempt Heartbeat Local Checkpoint (2026-08-30)

Heartbeat acquisition is now an explicit fallible effect on the AWS-admin Kubernetes boundary and
the coordinator invokes it after durable preparation but before any Job create. The sampled value
is passed explicitly through render, exact Job/Pod observation, Authority attestation, and
pre-delete exact-object observation. Stable absence remains keyed by the immutable cleanup UIDs.
Completed recovery takes the heartbeat from the signed Job binding and cannot invoke the clock;
clock failure creates no Job and has its own structured coordinator error. The retained plan and
permit deadlines and both Authority freshness checks remain unchanged.

The named counterexample holds topology, resources, deadline, and all Kubernetes/provider effects
constant. The frozen mapping is two sequential attempts `[h0, h0]`, where the successor can start
more than 30 seconds after `h0`; the replacement mapping is `[h0, h1]`, with one exact value reused
inside each attempt. Tests prove the replacement mapping, no-effect clock failure, and signed-value
recovery cleanup. Focused Sprint-2.123 passes **3/3**, the complete AWS-admin Authority group
**50/50**, primary **4747/4747**, and auxiliary suites **27/33/31**. Repository policy, Fourmolu,
HLint (`No hints`), warning-clean all-target compilation, documentation, and diff gates pass;
canonical `prodbox dev check` exits 0. Its gate-built and installed executable is byte-identical at
`sha256:bfbc6201b331a93d14253628ab994a3680620b69a34379843d8ba4689e31b83f`. The retained-attempt
fence expired at 21:33:43 EDT; Generation 134 is admitted.

### Generation-134 Per-Attempt Heartbeat Live Proof (2026-08-30)

Generation 134 starts after a clean 21:35:09 EDT preflight and explicit 21:35:31 start. It builds
local image `sha256:58d18632adb637f85883da5b27885dea42a3a95b43b9ba0ad66ad3f88d892eda`
in 993.8 seconds, publishes registry manifest
`sha256:d2e1ca8d682176a076983f66bd833b830ef436424d532829c14777868609941c`, and imports OCI
manifest `sha256:01dddf358d3e5ad2bb13b35aae34223c13a31e77e5f30f84a6fc93cc1e16d522` in
144.2 seconds. It removes only Generation 133's superseded local image and untagged registry
manifest. Retained root session and digest remain exact.

Exact-image Target Agent generation 79 and Lifecycle Authority generation 21 start at 21:59:38
and 22:00:04 EDT. Credential attempts start at 22:00:23 and 22:00:45; the first is killed at
22:00:41 and the fresh-heartbeat successor crosses attestation before its 22:00:55 cleanup. A
Target worker starts at 22:00:32 and is killed at 22:00:39. The exact later terminal is
`execution-failed/target-observation-unobservable/client/response-codec/invalid/status/server`,
which live-proves Sprint `2.123` and the Sprint-2.122 classifier. Register stable counterexample
`TARGET-MATERIAL-CODEC-INVALID-SERVER-SHAPE-2026-08-30` under Sprint `2.124` before changing the
outer response behavior.

Postflight at 22:01:28 proves no credential or Target one-shot residue, both retained workloads
Ready on the exact image, a Ready pressure/taint-free node, and 41 GiB free. The conservative
retained-attempt fence runs through 22:31:15 EDT; no Generation 135 command may start before
22:31:16.

## Sprint 2.124: Classify Codec-Invalid Target Server Response Shape [✅ Done]

**Status**: Done on its code-owned surface (2026-08-30); its current-revision deployment proof
remains pending behind the separately registered Sprint-2.125 aggregate-backup boundary.
**Implementation**: `src/Prodbox/ControlPlane/AuthenticatedRoleInterpreter.hs` and
`src/Prodbox/ControlPlane/TargetMaterialClient.hs`, with focused validation under
`test/unit/CredentialProvisionerAwsAdminAuthority.hs`.
**Deployment qualification**: pending — a supported reconcile must identify and cross the exact
Generation-134 server-response boundary.
**Independent Validation**: pure response-shape classification and injected Target client
responses prove the diagnostic without AWS, Kubernetes, Vault, MinIO, retained replay state,
response detail, or Target material.
**Docs to update**: `documents/engineering/lifecycle_control_plane_architecture.md`,
`documents/engineering/lifecycle_reconciliation_doctrine.md`, `DEVELOPMENT_PLAN/README.md`,
`DEVELOPMENT_PLAN/00-overview.md`, and `DEVELOPMENT_PLAN/system-components.md`.

### Objective

Determine which exact static outer authenticated-role plaintext response accompanies the
codec-invalid server-class Target response, without retaining arbitrary body bytes and without
changing authentication, replay, server, decoding, observation, retry, cleanup, receipt, or
admission behavior.

### Deliverables

- Define one closed value-free cause for every exact plaintext response owned by the authenticated
  role interpreter, with an explicit `other` fallback.
- Classify only an exact status/body pair; arbitrary or private bodies, prefixes, suffixes, and
  known text at the wrong status collapse to `other` and remain unrepresentable.
- Refine only the Target-material codec-invalid server cause; preserve every non-server status,
  decoded response, transport, remote refusal, and production behavior.
- Add exhaustive unique-token, exact-pair, near-miss/private-body-collapse, and production seam
  tests.
- Deploy after the retained-attempt fence and register any later distinct refusal before changing
  its behavior.

### Validation

1. Every authenticated-role plaintext response maps to one unique payload-free cause only at its
   authored status; all other bodies map to `other`.
2. Focused Target-material/AWS-admin tests, the complete local suite, documentation/diff checks,
   and canonical `prodbox dev check` pass before deployment.
3. Generation 135 identifies and crosses
   `TARGET-MATERIAL-CODEC-INVALID-SERVER-SHAPE-2026-08-30`; any later distinct refusal is
   registered first.

### Local checkpoint (2026-08-30)

The authenticated-role interpreter now owns one total projection of its 21 static status/body
pairs. Its classifier recognizes only an exact pair and returns a closed payload-free observation;
wrong-status text, prefixes, suffixes, arbitrary/private bodies, and all responses outside that
family become `other`. The Target-material decoder applies this refinement only after a
server-class response fails canonical decoding and retains neither response bytes nor numeric
status. Authentication, replay, rendering, decoding, Target observation, retry, cleanup, receipt,
and admission decisions are unchanged.

The focused Sprint-2.124 and combined Sprint-2.122/2.124 cases pass **2/2**, the complete AWS-admin
Authority group **51/51**, the primary suite **4748/4748**, and the isolated auxiliary suites
**27/33/31**. Repository policy, Fourmolu, HLint (`No hints`), warning-clean compilation of every
target, documentation, diff, and canonical `prodbox dev check` gates pass. The gate-built and
installed executable is byte-identical at
`sha256:28c6928d165c2fdfb66f1b9e165d60cf30b1be4ab8be194bc516d0f90b915006`.

### Generation 135 deployment observation (2026-08-30; incomplete evidence)

The supported reconcile starts at 22:31:26 EDT and builds local image
`sha256:2e6c9f0fe4312ed5e3d8917a7dea6e07c0aa3fdede7af58ce443b28f9b751bc3` in
994.6 seconds, publishes registry manifest
`sha256:a8eb3e55dc8bfca5fd03d3ac6cee662fa55b11a020c135290728c19e5be049e2`, and imports
OCI manifest `sha256:cb8e07e40657adbed770d5419b8d9e1f66ef278b71df93a254115d4fa74ff2aa`
in 153.8 seconds. Retention removes exactly Generation 134's superseded registry manifest and
local image. Exact-image Target Agent and Lifecycle Authority containers start at 22:55:59 and
22:56:25. The credential worker starts at 22:56:45, the Target worker starts at 22:56:56, and
they are killed at 22:57:06 and 22:57:03 respectively.

The outer command-output observer truncates the very large Docker stream before retaining the
later terminal line, so this invocation supplies **no completion evidence** for Sprint `2.124`
and no later refusal is inferred. Postflight at 22:59:02 proves zero one-shot Jobs, both retained
workloads Ready on the exact image, a Ready pressure/taint-free node, and 41 GiB free. The
conservative retained-attempt fence runs through 23:27:26 EDT; no Generation 136 command is
admitted before 23:27:27. Generation 136 must retain the exact protected terminal through a
filtered observation of the otherwise unchanged supported command.

### Generation 136/137 earlier-boundary observation (2026-08-30)

After the exact Generation-135 fence, Generation 136 starts at 23:28:19 EDT under a bounded
filtered observer, reuses the unchanged local image and registry manifest, exits 1 before creating
any credential or Target Job, and exposes no retained-attempt fence. Generation 137 starts at
23:30:45 with the observer widened to all unavailable, unobservable, invalid, refusal, failure,
and error lines. It retains exact terminal
`Authority backup admission reconciliation failed: AuthorityBackupHealthObservationFailed
"AuthorityAggregateBackupResponseInvalid ControlPlaneRequestInvalid"`, exits 1, and likewise
creates no one-shot Job. Register stable counterexample
`AUTHORITY-AGGREGATE-BACKUP-RESPONSE-CODEC-INVALID-2026-08-30` under Sprint `2.125`. No
Target-response cause is inferred and the Sprint-2.124 live proof remains pending.

### Remaining Work

None on the code-owned surface. Current-revision live proof remains pending under Standard P.

## Sprint 2.125: Classify Codec-Invalid Aggregate-Backup Response Shape [✅ Done]

**Status**: Done on the code-owned surface — registered from Generation 137 and locally closed
without changing the aggregate-backup client decision or Authority Backup response.
**Implementation**: `src/Prodbox/ControlPlane/AuthorityBackupClient.hs`, with focused validation
under `test/unit/ControlPlaneAuthorityBackupEndpoint.hs`.
**Live-proof**: pending — Generations 138/139 stop at earlier rollout/config-client boundaries.
**Deployment qualification**: pending — a supported reconcile must identify and cross the exact
Generation-137 response boundary.
**Independent Validation**: injected aggregate-backup transport responses exercise the existing
exact authenticated-role classifier without Kubernetes, Vault, MinIO, retained replay state,
ciphertext, or live backup data.
**Docs to update**: `documents/engineering/lifecycle_control_plane_architecture.md`,
`documents/engineering/lifecycle_reconciliation_doctrine.md`, `DEVELOPMENT_PLAN/README.md`,
`DEVELOPMENT_PLAN/00-overview.md`, and `DEVELOPMENT_PLAN/system-components.md`.

### Objective

Determine whether the codec-invalid aggregate-backup response is one exact static
authenticated-role plaintext response, without retaining response bytes and without changing
authentication, replay, backup observation, health classification, retry, admission, or response
behavior.

### Stable Counterexample (2026-08-30)

Generation 137 exits before any one-shot Job with exact terminal
`AuthorityBackupHealthObservationFailed "AuthorityAggregateBackupResponseInvalid
ControlPlaneRequestInvalid"`. The aggregate client discards the response status and body after the
codec failure, so the exact outer response family is not observable. Stable counterexample:
`AUTHORITY-AGGREGATE-BACKUP-RESPONSE-CODEC-INVALID-2026-08-30`.

### Deliverables

- Attach the existing closed `AuthenticatedRolePlainResponseObservation` to only the
  aggregate-backup client's codec-invalid response error at the decode boundary.
- Reuse the interpreter-owned exact status/body classifier: exact authored pairs retain their
  unique payload-free cause; arbitrary/private bodies, prefixes, suffixes, and known text at the
  wrong status become `other`.
- Preserve the checkpoint-backup client and every transport, status, decoded observation,
  receipt-validation, health, retry, admission, and response decision.
- Add exact-pair production-seam and private/near-miss collapse tests, then deploy the unchanged
  behavior and register any later distinct refusal before changing it.

### Validation

1. Every exact authenticated-role plaintext pair reaches the aggregate client error as its unique
   closed observation; all near misses and private bodies reach `other` without bytes or status.
2. Focused Authority Backup tests, the complete local/auxiliary suites, documentation/diff gates,
   and canonical `prodbox dev check` pass.
3. Generation 138 identifies and crosses
   `AUTHORITY-AGGREGATE-BACKUP-RESPONSE-CODEC-INVALID-2026-08-30`; any later distinct refusal is
   registered first.

### Local validation checkpoint (2026-08-30)

The behavior-neutral diagnostic is complete on its code-owned surface. The aggregate-backup
decoder now attaches the interpreter-owned closed observation only when canonical decoding fails;
the checkpoint-backup client is unchanged. The production decode seam exhausts all 21 exact
status/body pairs and proves that wrong status, prefix, suffix, and distinct private bodies collapse
to `other`. Focused Sprint-2.125 passes **1/1**, the complete Authority Backup group **19/19**,
primary **4749/4749**, and auxiliary suites **27/33/31**. Repository policy, Fourmolu, HLint
(`No hints`), warning-clean compilation of every target, documentation, diff, and canonical
`prodbox dev check` gates pass. The gate-built and installed executable is byte-identical at
`sha256:1724e92e4d2d9109bbb73d6450e9bb63a2572cad21733e068dc9967c3cb885bc`. Generation 138 is
admitted with only the live counterexample proof outstanding.

### Generation 138 rollout-transition observation (2026-08-30/31)

The supported reconcile starts at 23:57:22 EDT and builds local image
`sha256:2486c0f518f9b9e91d4f9f9b34c80013467d525d2a2798af55092af02b2f9a3a`, publishes registry
manifest `sha256:05f7561da5239155394d294d1435204a586078b6357652e8a46941d279f19483`, and imports OCI
manifest `sha256:f6609c760c4a3c3d7780f7d25db245fdda9af6c26fc73aefe31c4b73d8646f36`. It removes only
Generation 135's superseded registry manifest and local image. The command exits 1 at 00:23:10
with the earlier terminal `Lifecycle Authority config is unobservable: ConfigBackupTransportFailed
(AuthenticatedClientTransportFailed (ControlPlaneTransportFailed (HttpTimeout "connection
timeout")))`; it never reaches the Sprint-2.125 boundary and is not completion evidence.

Postflight at 00:23:29 proves zero one-shot Jobs and therefore no retained-attempt fence. Target
Agent generation 81, Lifecycle Authority generation 23, and Authority Backup generation 63 are all
Ready on the exact new image; the node is Ready, pressure/taint-free, and has 36 GiB free. Generation
139 retries the unchanged proof against that settled revision.

### Generation 139 earlier-boundary observation (2026-08-31)

The supported reconcile starts at 00:25:39 EDT, reuses exact local image
`sha256:2486c0f518f9b9e91d4f9f9b34c80013467d525d2a2798af55092af02b2f9a3a` and registry
manifest `sha256:05f7561da5239155394d294d1435204a586078b6357652e8a46941d279f19483`, and exits 1 at
00:27:02 with exact terminal `Lifecycle Authority in-force config is unobservable:
ConfigBackupResponseInvalid ControlPlaneRequestInvalid`. The connection-timeout transition does
not recur, but the command stops at this earlier config-client codec boundary and therefore does
not supply Sprint-2.125 live proof. Postflight at 00:27:21 proves zero one-shot Jobs, no fence,
zero-restart exact-image Ready retained workloads, a pressure/taint-free Ready node, and 36 GiB
free. Register the distinct boundary under Sprint `2.126` before changing it.

### Remaining Work

None on the code-owned surface. Current-revision live proof remains pending under Standard P.

## Sprint 2.126: Classify Codec-Invalid In-Force-Config Response Shape [✅ Done]

**Status**: Done and live-proven — Generation 141 reports the exact static replay-capacity response
without retaining response bytes or changing config behavior.
**Implementation**: `src/Prodbox/ControlPlane/ConfigBackupClient.hs`, with focused validation under
`test/unit/ControlPlaneConfigEndpoint.hs`.
**Deployment qualification**: proven on the owned diagnostic boundary; Sprint `2.127` owns the
separately registered replay-capacity correction.
**Independent Validation**: injected config-backup responses exercise the existing exact
authenticated-role classifier without Kubernetes, Vault, MinIO, retained replay state, config
payloads, or live backup data.
**Docs to update**: `documents/engineering/lifecycle_control_plane_architecture.md`,
`documents/engineering/lifecycle_reconciliation_doctrine.md`, `DEVELOPMENT_PLAN/README.md`,
`DEVELOPMENT_PLAN/00-overview.md`, and `DEVELOPMENT_PLAN/system-components.md`.

### Objective

Determine whether the codec-invalid config-backup response is one exact static authenticated-role
plaintext response, without retaining response bytes and without changing authentication, replay,
config backup, in-force projection, retry, reconciliation, or response behavior.

### Stable Counterexample (2026-08-31)

Generation 139 exits before any one-shot Job with exact terminal `Lifecycle Authority in-force
config is unobservable: ConfigBackupResponseInvalid ControlPlaneRequestInvalid`. The config-backup
client discards the response status and body after codec failure, so the exact outer response family
is not observable. Stable counterexample:
`LIFECYCLE-AUTHORITY-IN-FORCE-CONFIG-RESPONSE-CODEC-INVALID-2026-08-31`.

### Deliverables

- Attach the existing closed `AuthenticatedRolePlainResponseObservation` to only the config-backup
  client's codec-invalid response error at the decode boundary.
- Reuse the interpreter-owned exact status/body classifier: exact authored pairs retain their
  unique payload-free cause; arbitrary/private bodies, prefixes, suffixes, and known text at the
  wrong status become `other`.
- Preserve both config copy and observation paths and every transport, status, decoded observation,
  receipt-validation, in-force projection, retry, reconciliation, and response decision.
- Add exact-pair production-seam and private/near-miss collapse tests, then deploy the unchanged
  behavior and register any later distinct refusal before changing it.

### Validation

1. Every exact authenticated-role plaintext pair reaches the config-backup client error as its
   unique closed observation; all near misses and private bodies reach `other` without bytes or
   status.
2. Focused config endpoint tests, the complete local/auxiliary suites, documentation/diff gates,
   and canonical `prodbox dev check` pass.
3. Generation 140 identifies and crosses
   `LIFECYCLE-AUTHORITY-IN-FORCE-CONFIG-RESPONSE-CODEC-INVALID-2026-08-31`; any later distinct
   refusal is registered first.

### Local validation checkpoint (2026-08-31)

The behavior-neutral diagnostic is complete on its code-owned surface. The config-backup decoder
now attaches the interpreter-owned closed observation only when canonical decoding fails; both
copy/observe decisions and the checkpoint-backup client are unchanged. The production decode seam
exhausts all 21 exact status/body pairs and proves that wrong status, prefix, suffix, and distinct
private bodies collapse to `other`. Focused Sprint-2.126 passes **1/1**, the complete in-force-config
endpoint group **11/11**, primary **4750/4750**, and auxiliary suites **27/33/31**. Repository
policy, Fourmolu, HLint (`No hints`), warning-clean compilation of every target, documentation,
diff, and canonical `prodbox dev check` gates pass. The gate-built and installed executable is
byte-identical at
`sha256:968b92038bba64be3bd9d784f30d253dac489a5ba4c05b68cafac1ba5cb5a8cb`. Generation 140 is
admitted with only the live counterexample proof outstanding.

### Generation 140 rollout-transition observation (2026-08-31)

The supported reconcile starts at 00:44:25 EDT and builds local image
`sha256:1ebf04acf174d93552aaa6bdac2016ee14c40dfe5fbe19360b482db500f457e5`, publishes registry
manifest `sha256:f3df35ba67c80dc3cc459904590ae36f5a733bd8fcf2cf7bbfaa1a1e831c0785`, and imports OCI
manifest `sha256:a8274de5821695988fa72b0c45e7d367cf16e6d7058064822a1d3f93fc31035d`. It removes only
Generation 138/139's superseded registry manifest and local image. The command exits 1 at 01:07:37
with the earlier terminal `Lifecycle Authority config is unobservable: ConfigBackupTransportFailed
(AuthenticatedClientTransportFailed (ControlPlaneTransportFailed (HttpTimeout "connection
timeout")))`; it never reaches the Sprint-2.126 boundary and is not completion evidence.

Postflight at 01:07:56 proves zero one-shot Jobs and therefore no retained-attempt fence. Target
Agent generation 82, Lifecycle Authority generation 24, and Authority Backup generation 64 are all
zero-restart Ready on the exact new image; the node is Ready, pressure/taint-free, and has 36 GiB
free. Generation 141 retries the unchanged proof against that settled revision.

### Generation 141 deployment observation (2026-08-31)

The supported reconcile starts at 01:09:06 EDT, reuses exact local image
`sha256:1ebf04acf174d93552aaa6bdac2016ee14c40dfe5fbe19360b482db500f457e5` and registry
manifest `sha256:f3df35ba67c80dc3cc459904590ae36f5a733bd8fcf2cf7bbfaa1a1e831c0785`, and exits 1 at
01:10:29 with exact terminal `Lifecycle Authority in-force config is unobservable:
ConfigBackupResponseInvalid ControlPlaneRequestInvalid
(AuthenticatedRolePlainResponseKnown AuthenticatedRoleReplayCapacityExhausted)`. This identifies
and crosses Sprint `2.126`'s opaque codec boundary. Postflight at 01:10:50 proves zero one-shot Jobs,
no fence, zero-restart exact-image Ready retained workloads, a pressure/taint-free Ready node, and
36 GiB free. Register the distinct capacity behavior under Sprint `2.127` before changing it.

### Remaining Work

None.

## Sprint 2.127: Retained Replay Covers One Immediate Complete Reconcile Retry [✅ Done]

**Status**: Done — Generation 147 live-proves the role-specific correction on an immediate
unchanged retry without clearing retained entries.
**Implementation**: `src/Prodbox/ControlPlane/Runtime.hs`,
`src/Prodbox/ControlPlane/RequestReplay.hs`, with focused validation in
`test/control-plane-authenticated-transport/Main.hs` and `test/unit/Main.hs`.
**Deployment qualification**: proven — Generations 146/147 deploy and immediately retry the exact
runtime, cross both replay counterexamples, and proceed to a later Provider Worker boundary.
**Independent Validation**: pure request traces exercise two complete Lifecycle Authority and
Authority Backup request envelopes plus canonical non-empty v2/v3/v4/v5 retained projections
without Kubernetes, Vault, MinIO, wall-clock waits, or live replay state.
**Docs to update**: `documents/engineering/lifecycle_control_plane_architecture.md`,
`documents/engineering/lifecycle_reconciliation_doctrine.md`, `DEVELOPMENT_PLAN/README.md`,
`DEVELOPMENT_PLAN/00-overview.md`, and `DEVELOPMENT_PLAN/system-components.md`.

### Objective

Make each authenticated role participating in the reconcile retain enough replay authority for one
complete supported reconcile and one immediate unchanged retry inside the original request lifetime
plus skew, without deleting, expiring early, overwriting, or bypassing any retained
nonce/digest/deadline/response entry.

### Stable Counterexample (2026-08-31)

Generation 140 fills the retained window during its otherwise supported rollout attempt and exits
at the post-rollout config-read timeout. Generation 141 begins unchanged while those entries remain
inside the five-minute deadline plus one-minute skew and reaches exact
`AuthenticatedRoleReplayCapacityExhausted` at the in-force-config load. Stable counterexample
`LIFECYCLE-REPLAY-IMMEDIATE-RETRY-WINDOW-2026-08-31` holds topology, load, and command constant
across the rollout invocation and immediate retry.

The existing hard first-reconcile request maximum is 56. A complete attempt then performs exactly
four authenticated config requests: observe current generation, propose and read back the exact
generation, freshly observe the same projection while reconciling the Authority-bound retained-root
marker, and load the in-force projection. Two complete attempts therefore require
`2 * (56 + 4) = 120` retained entries before any deadline-plus-skew compaction is available.

Generation 145 starts more than six hours after the prior attempt, so every earlier entry is beyond
that horizon, but the same exact refusal recurs at the final load. The response is nested through
`ConfigBackupClient`; its authenticated server is Authority Backup, not Lifecycle Authority. One
settled attempt sends the Adapter backup health plus four config-backup observations, so its generic
capacity four refuses request five. The complete Adapter envelope also covers the repair arm's
observe/copy/final-health maximum of three and the changed-config arm's initial observe,
copy/read-back, promotion read-back, marker observe, and final load maximum of six. Two complete
worst-case attempts therefore require `2 * (3 + 6) = 18` Adapter entries. Stable counterexample
`AUTHORITY-BACKUP-REPLAY-SINGLE-COMPLETE-RECONCILE-2026-08-31` holds source, load, topology, and
command constant and requires no retained pressure from an earlier invocation.

### Deliverables

- Derive the Lifecycle Authority replay capacity from two supported attempts of the exact
  60-request first-reconcile-plus-config/marker envelope.
- Derive the Authority Backup replay capacity from two nine-request repair-plus-config envelopes;
  apply it only to that Adapter and leave the other sibling roles at capacity four. Leave
  response-size, encoded-byte, clock-skew, and CAS-attempt bounds unchanged.
- Advance the replay codec and admit canonical v2, v3, v4, or v5 projections only when their capacity is no
  greater than the compiled target and all non-capacity limits match exactly. Preserve every entry,
  project current limits in memory, and write v6 on the next CAS. Refuse shrink, limit drift,
  corruption, duplicate keys, noncanonical bytes, over-capacity entries, and unknown versions.
- Add a pure trace in which capacity 64 accepts the first complete 60-request attempt and only the
  first four requests of the immediate retry, while the derived capacity admits all 120 without
  compaction. Add the Adapter trace in which capacity four refuses request five and capacity 18
  admits two complete nine-request envelopes. Add non-empty v2, v3, v4, and v5 widening/migration
  cases plus current-v6 round trip.
- Deploy through the unchanged supported command and register any later distinct refusal before
  changing it.

### Validation

1. The pure two-attempt trace reproduces capacity exhaustion at retry request five under capacity
   64 and admits all 120 requests under the derived capacity with every retained entry present.
2. The Adapter trace reproduces capacity-four exhaustion at request five and admits 18 requests
   under the role-specific bound with every retained entry present.
3. Canonical v2/v3/v4/v5 widening preserves non-empty entries and rewrites v6; current v6 round-trips;
   shrink, response/skew drift, malformed/noncanonical bytes, over-capacity entries, and unknown
   versions refuse.
4. Focused authenticated-transport tests, the complete local/auxiliary suites,
   documentation/diff gates, and canonical `prodbox dev check` pass.
5. A fresh supported rollout and immediate unchanged retry cross both registered replay
   counterexamples without clearing retained entries.

### Superseded local validation checkpoint (2026-08-31)

The initial replay correction derived 59 requests per attempt and 118 for the rollout plus immediate
retry. Its pure trace proved that model, and canonical non-empty v2/v3 projections widened into v4
with every entry preserved; shrink and non-capacity drift remained closed.
The complete retained-replay suite passes **32/32**, the focused primary runtime assertion **1/1**,
primary **4750/4750**, and auxiliary suites **27/33/32**. Repository policy, Fourmolu, HLint
(`No hints`), warning-clean compilation of every target, documentation, diff, and canonical
`prodbox dev check` gates pass. The gate-built and installed executable is byte-identical at
`sha256:9ef3f378928fe9c28dc684dc22b97fc866e6ed820b31582b5fa5eb113432ba23`. The live sequence below
falsifies the 59/118 derivation, so this is not a current closure checkpoint.

### Generation 142/143 live count counterexample (2026-08-31)

Generation 142 starts at 01:31:17 EDT, builds local image
`sha256:331dbc9d3653051bb8ea8288f650b363e9bf49a6160e76d7274ea688a4ea7e06`, publishes registry
manifest `sha256:c5a4b0fbc050227595d4d98c0d388e0443983b63a200e832a7f3eec15ed4d0d6`, and imports OCI
manifest `sha256:3e153121d9aa13a2129891782b35625d9abbb9115c0eac5334f477e01569fea7`. It removes only
Generation 140/141's superseded registry manifest and local image and exits at 01:54:25 with the
known rollout-transition config timeout. Postflight at 01:54:55 proves zero one-shot Jobs/no fence
and zero-restart exact-image Ready Target Agent generation 83, Lifecycle Authority generation 25,
and Authority Backup generation 65.

Generation 143 starts at 01:55:07, 42 seconds after the rollout exit and inside the retained
horizon, reuses the exact image/manifest, and exits at 01:56:30 with exact
`ConfigBackupResponseInvalid ControlPlaneRequestInvalid
(AuthenticatedRolePlainResponseKnown AuthenticatedRoleReplayCapacityExhausted)`. Source closure
identifies the omitted request: `reconcileAuthorityBoundRetainedRootMarker` performs a fresh
authenticated config observation after proposal and before final load. Generation 142 retains the
59 requests that reached Authority before its timed-out load; Generation 143 accepts another 59,
then its final load is request 119 and capacity 118 refuses it. Correct the complete-attempt model
to 60, capacity to 120, and the already-live v4/118 widening migration to v5.

### Superseded Lifecycle-Authority-only validation checkpoint (2026-08-31)

Production now derives 60 requests per complete attempt and capacity 120 for two attempts. The pure
trace proves capacity 64 accepts the first 60 and only four retry requests before refusing retry
request five, while the current bound retains all 120 without compaction. Canonical non-empty v2,
v3, and the deployed v4/118 projection widen into v5 with every entry preserved; shrink and
non-capacity drift remain closed. The complete retained-replay suite passes **32/32**, the focused
primary runtime assertion **1/1**, primary **4750/4750**, and auxiliary suites **27/33/32**.
Repository policy, Fourmolu, HLint (`No hints`), warning-clean compilation of every target,
documentation, diff, and canonical `prodbox dev check` gates pass. The corrected gate-built and
installed executable is byte-identical at
`sha256:1076bab06d59979d4483dde1e6b3ab44d0c1f0f65673cedf1ef5ed27d79d6aec`.

This checkpoint correctly sizes the Lifecycle Authority side but leaves Authority Backup on the
generic capacity four. Generation 145 below falsifies it as a complete Sprint-2.127 correction.

### Generation 144/145 role-boundary counterexample (2026-08-31)

Generation 144 starts at 02:15:36 EDT, builds local image
`sha256:a78b97c3b46cdeec823e02c8ba0110957de4c53e9338c38444ec5f42dd874e13`, publishes registry
manifest `sha256:3542ca14aee5aedd887cde5cbf3ca1d35d47374870f1aa73761efb5787442b3e`, and imports OCI
manifest `sha256:81f1438a573a91d316a53e3929fbc1da572c8f47d3889a9721b1852275ac1332`. It removes only
Generation 142/143's superseded registry manifest and local image, then exits at 02:38:42 with the
known rollout-transition config timeout. The shell resumes only at 09:14:16, so this run has no
immediate-retry successor and supplies no capacity proof. Read-only postflight then shows no
one-shot Job and zero-restart Ready Target Agent generation 84, Lifecycle Authority generation 26,
and Authority Backup generation 66 on exact image tag
`prodbox-3349a232b3454fb3be77b2f68919904f`.

Generation 145 starts at 09:15:00 EDT against those settled workloads and exits 1 at 09:16:27 with
exact `ConfigBackupResponseInvalid ControlPlaneRequestInvalid
(AuthenticatedRolePlainResponseKnown AuthenticatedRoleReplayCapacityExhausted)`. The more-than-six-
hour gap exceeds every five-minute deadline plus one-minute skew horizon, so the refusal cannot be
pressure retained from Generation 144 or earlier. Source closure follows `ConfigBackupClient` to
the Authority Backup Adapter, whose runtime still receives `standardReplayCapacity = 4`. The
settled path sends that Adapter one backup-health observation followed by config observe,
unchanged-proposal read-back, retained-root-marker observation, and final in-force load. The final
load is request five and fails before the endpoint handler. This registers stable counterexample
`AUTHORITY-BACKUP-REPLAY-SINGLE-COMPLETE-RECONCILE-2026-08-31` and corrects the earlier assumption
that the nested response proved Lifecycle Authority saturation.

### Current role-specific local checkpoint (2026-08-31)

Lifecycle Authority retains its compiled 120-entry two-attempt envelope. Authority Backup alone
now receives capacity 18, derived from a per-attempt maximum of three aggregate-repair requests plus
six config-backup requests. TLS Retention, Provider Worker, and Target Secret Agent remain on the
generic four-entry bound. The replay codec advances to v6 and admits canonical v2/v3/v4/v5
widening only; this covers both deployed v5 shapes (Authority 120 and Adapter four) without deleting
an entry or relaxing any other limit. The focused retained-replay suite passes **33/33**, including
capacity-four request-five refusal, both complete Adapter envelopes, both complete Authority
envelopes, non-empty migration for all four legacy versions, current-v6 round-trip, and refusal of
shrink/non-capacity drift. The focused primary assertion passes **1/1**, primary **4750/4750**, and
auxiliary suites **27/33/33**. Repository policy, Fourmolu, HLint (`No hints`), warning-clean
all-target compilation, documentation, diff, and canonical `prodbox dev check` gates pass. The
gate-built and installed executable is exact at
`sha256:b3e8a965db2e37839f8b888feb26ca238ef453fb40b461904cb0921b369647b7`.

Both canonical integration invocations independently report **55/63** passing and the same eight
fixture failures. Seven stop at the Phase-5-owned fake runtime-image-retention observation and one
at the already-registered fake Helm status arm before reaching the cases' intended assertions;
none exercises or fails the Sprint-2.127 role/replay surface. Sprint `5.38` owns that later suite-
content repair. Under Standard N, this phase's independent focused/unit/canonical validation does
not depend on that later phase.

### Remaining Work

None.

### Generation 146/147 live proof (2026-08-31)

Generation 146 starts at 10:01:22 EDT, builds local runtime image
`sha256:37941ace2d1574a8136bb8a1df1e1833bae8820c5995b34a8e6bac12f4577fd1`, and publishes
registry manifest `sha256:6a05e85978fbd766249d69860c7853c7ee4506894457e4eac59a7fbdcc9a12b4`. It rolls Target Agent,
Lifecycle Authority, and Authority Backup to generations 85, 27, and 67 and exits 1 at 10:24:41
with the expected rollout-transition `ConfigBackupTransportFailed ... HttpTimeout \"connection
timeout\"` before a settled config observation.

Generation 147 starts unchanged at 10:25:15, 34 seconds after that terminal and inside the retained
request horizon. It reuses the exact local image and registry manifest, reports that the proposed
Authority config and retained-root marker are already current, and crosses the former Lifecycle
Authority and Authority Backup replay-capacity refusals without clearing retained entries. It exits
1 at 10:29:40 only after reaching the later Provider dispatch, with exact
`ProviderWorkerTransportFailed ... host name: Just
\"provider-worker.provider-worker.svc.cluster.local\" ... does not exist`. Postflight proves no
one-shot Jobs; zero-restart Ready Target Agent, Lifecycle Authority, and Authority Backup Pods on
exact local image `37941ace...`; no `provider-worker` namespace; a Ready untainted node; and 33 GiB
free. This completes validation item 5 and closes Sprint `2.127`.

## Sprint 2.128: Provider Worker Exists Before First Provider Dispatch [✅ Done]

**Status**: Done — Generation 149 live-proves the Provider Worker Service and ready endpoint exist
before the first Provider dispatch.
**Implementation**: `src/Prodbox/Config/ComponentGraph.hs`, with native-order validation in
`test/unit/Main.hs` and exact binary-sibling Tier-0 graph projection.
**Deployment qualification**: proven — Generation 149 creates and observes the exact ready worker,
crosses DNS absence, and reaches a later dispatch timeout.
**Independent Validation**: pure topology/order tests must prove every first Provider dispatch is
dominated by exact Provider Worker availability without Kubernetes, DNS, Vault, or wall-clock
waits.
**Docs to update**: `documents/engineering/lifecycle_control_plane_architecture.md`,
`documents/engineering/lifecycle_reconciliation_doctrine.md`, `DEVELOPMENT_PLAN/README.md`,
`DEVELOPMENT_PLAN/00-overview.md`, and `DEVELOPMENT_PLAN/system-components.md`.

### Objective

Make the declared retained Provider Worker topology observable before Lifecycle Authority performs
its first Provider dispatch, while preserving the authenticated client boundary and failing closed
when the exact retained service is unavailable.

### Stable Counterexample (2026-08-31)

Generation 147 crosses Sprint `2.127` and then fails while loading operational AWS credentials with
exact `AuthorityProviderRemoteRefused 503` wrapping
`ProviderWorkerTransportFailed ... provider-worker.provider-worker.svc.cluster.local ... does not
exist`. Immediate read-only postflight finds no `provider-worker` namespace, Service, Deployment,
or StatefulSet. Stable counterexample
`PROVIDER-WORKER-DNS-ABSENT-BEFORE-FIRST-PROVIDER-DISPATCH-2026-08-31` holds command, substrate,
retained root, and runtime identity constant.

Source closure projects the production dry-run as
`load_authority_in_force_settings -> ensure_gateway_chart_ready ->
ensure_root_chart_namespace_guardrails -> ensure_provider_worker_chart_ready`. The namespace
guardrail calls `resolveOperationalAwsCredentialGate`, which dispatches
`ObserveProviderReadiness ProviderReadinessStsIdentity` through Lifecycle Authority. Both
`ComponentGatewayDaemonFull` and `ComponentChartProviderWorker` depended only on Authority Backup,
so the stable constructor order selected Gateway first even though its component group already
contained a Provider consumer. The exact owner is therefore the missing graph edge, not DNS retry,
Service naming, endpoint authentication, or chart deployment.

The correction adds `orderingOn ComponentChartProviderWorker` to
`ComponentGatewayDaemonFull`. The pure order assertion requires Provider Worker readiness before
both Gateway chart reconciliation and the namespace guardrail. The rebuilt dry-run now projects
`load_authority_in_force_settings -> ensure_provider_worker_chart_ready ->
ensure_gateway_chart_ready -> ensure_root_chart_namespace_guardrails`; the focused assertion passes
**1/1**. The authored binary-sibling Tier-0 graph carries the same exact dependency and the
installed executable is `sha256:094803cd0f773a69b77c40acc5bf9ef3c70bc58df5dff3d0e03f96fbd8488bd7`.

### Deliverables

- Trace the declared Provider Worker install, readiness, authenticated admission, and first-use
  order; identify the exact missing owner before changing behavior.
- Express the corrected order as typed/pure orchestration rather than a DNS retry, direct Provider
  fallback, or host-side mutation path.
- Preserve exact Service identity, NetworkPolicy, mTLS role, retained replay, and fail-closed
  transport semantics.
- Deploy through the unchanged supported command and register any later distinct refusal before
  changing it.

### Validation

1. A pure order/topology test reproduces the current first-use-before-availability path and proves
   the corrected path cannot dispatch before exact Provider Worker readiness.
2. Focused control-plane tests cover absent, unready, mismatched, and ready exact Service cases
   without weakening authenticated transport refusals.
3. Complete local/auxiliary suites, documentation/diff gates, and canonical `prodbox dev check`
   pass.
4. A supported live reconcile observes the exact Provider Worker and crosses the registered DNS
   boundary.

### Current local checkpoint (2026-08-31)

The production graph, authored binary-sibling Tier-0 record, native dry-run, home plan goldens, and
shared AWS projection all carry the same Provider-before-Gateway edge. The exact dependency/order
assertions pass; the parser-safe local focused group passes **105/105** and the individual
with-edge and AWS-order assertions pass **1/1** each. The primary suite passes **4750/4750** and
auxiliary suites **27/33/33**. Repository policy, generated-config/witness drift, Fourmolu, HLint
(`No hints`), warning-clean all-target compilation, documentation, diff, and canonical `prodbox dev
check` gates pass. The gate-built and installed executable is exact at
`sha256:094803cd0f773a69b77c40acc5bf9ef3c70bc58df5dff3d0e03f96fbd8488bd7`.

### Remaining Work

None.

### Generation 148/149 live proof (2026-08-31)

Before Generation 148, an observed host/RKE2 disruption has recreated several platform Pods and
left the prior zero-restart retained roles not-ready on the closed stale-authority-epoch cause.
Current preflight nevertheless proves the node Ready, untainted, and pressure-free with 6 GiB
memory available and 33 GiB disk free. Generation 148 starts at 11:19:43 EDT, recovers the retained
roles, builds local runtime image
`sha256:aad6464d79c76288a97f11cf2d87e372c2386df32b96eb8d4668b7227d495e4a`, publishes registry
manifest `sha256:f397770176ab975230e0dbee94f021575be8b45c4e620c0dab13c86afd3845f3`, rolls Target Agent,
Lifecycle Authority, and Authority Backup to generations 86, 28, and 68, and exits 1 at 11:43:05
on the expected rollout-transition config connection timeout.

Generation 149 starts unchanged at 11:43:40, 35 seconds later. It reuses the exact identities,
advances and reads back the new in-force config, confirms the retained-root marker, and follows the
corrected graph into Provider Worker creation before the Gateway group. It exits 1 at 11:47:13 on
exact `AuthorityProviderRemoteRefused 503` wrapping
`ProviderWorkerTransportFailed ... HttpTimeout \"connection timeout\"`, rather than DNS absence.
Postflight at 11:47:44 proves Provider Worker Deployment generation 1 with one available replica;
its zero-restart Ready Pod on exact image `aad6464d...`; ClusterIP Service and ready EndpointSlice
at `10.42.0.178:8600`; zero-restart Ready retained roles on the same image; no one-shot Jobs; a
Ready untainted pressure-free node; and 32 GiB free. This completes validation item 4 and closes
Sprint `2.128`.

## Sprint 2.129: Classify First Exact-Ready Provider Dispatch Timeout [✅ Done]

**Status**: Done — the live protected trace classifies the timeout before behavior changes.
**Implementation**: `src/Prodbox/ControlPlane/ProviderWorkerDiagnostic.hs`,
`ProviderWorkerClient.hs`, `ProviderWorkerExecution.hs`, and `Runtime.hs`; focused regressions in
`test/unit/ControlPlaneProviderWorkerExecution.hs`.
**Deployment qualification**: proven — Generations 150/151 deploy the exact diagnostic and locate
the refusal before owned-route socket ingress without weakening the exact Service/readiness or
authenticated transport boundary.
**Independent Validation**: the pure total stage/cause vocabulary collapses private
credential/Vault/provider/transport details; traced/untraced success, refusal, timeout, thrown
boundary, and exact authenticated-response regressions preserve the original decisions and bytes.
**Docs to update**: `documents/engineering/lifecycle_control_plane_architecture.md`,
`documents/engineering/lifecycle_reconciliation_doctrine.md`, `DEVELOPMENT_PLAN/README.md`, and
`DEVELOPMENT_PLAN/00-overview.md`.

### Objective

Identify the exact bounded stage at which the first ready Provider Worker dispatch stalls, using a
closed payload-free diagnostic that exposes no credential, Vault, AWS, subprocess, request, or
response detail and changes no behavior.

### Stable Counterexample (2026-08-31)

Generation 149 holds runtime identity, command, substrate, retained root, and Provider intent
constant after the corrected graph creates a Ready Provider Worker with an exact Service endpoint.
The first `ObserveProviderReadiness ProviderReadinessStsIdentity` dispatch ends as
`ProviderWorkerTransportFailed ... HttpTimeout \"connection timeout\"`. Stable counterexample
`PROVIDER-WORKER-FIRST-READY-DISPATCH-TIMEOUT-2026-08-31` distinguishes this from Sprint `2.128`'s
DNS absence.

### Deliverables

- Trace request admission through authenticated ingress, narrow-session/Vault acquisition,
  Provider execution, response rendering, and socket completion without changing any timeout.
- Add one exhaustive payload-free stage/cause projection at the smallest owned boundary; private
  text and values must collapse to closed constructors.
- Preserve the original Provider result, HTTP response, client timeout, replay entry, readiness,
  and exit behavior byte-for-byte.
- Deploy the diagnostic through the unchanged supported command and register any later distinct
  refusal before changing behavior.

### Validation

1. An exhaustive table proves every known stall/failure stage has one stable token and arbitrary
   private details cannot enter it.
2. Success, refusal, timeout, and thrown-boundary tests prove the diagnostic changes no returned
   value, HTTP response, or client decision.
3. Focused and complete local suites, documentation/diff gates, and canonical `prodbox dev check`
   pass.
4. A supported live reconcile identifies the exact protected stage/cause or crosses the timeout.

### Current Validation State

Source closure proves the production readiness observer and each Provider request independently
read the Provider credential, while the request then executes its own exact Provider capability.
The HTTP client distinguishes the observed `ConnectionTimeout` from its separate response timeout.
The closed diagnostic now spans owned-route socket ingress, fresh authenticated handler admission,
trust/time revalidation, Vault-backed narrow-session acquisition, opaque credential binding,
capability execution, Authority projection, response encoding, and the server-owned socket-write
completion. It carries only eleven exhaustive stage tokens and three exhaustive causes; no request
identifier or private value field exists. Synchronous observer failure is discarded and async
cancellation is rethrown unchanged. The focused Provider Worker suite passes **25/25**. The
primary suite passes **4753/4753**, auxiliary suites pass **27/33/33**, documentation/diff,
Fourmolu, HLint (`No hints`), warning-clean all-target compilation, and canonical `prodbox dev
check` pass. The gate-built executable is exact at
`sha256:7ba6d449b9a80ef1ef61002f4498301f59f22172348e71b3e6208577b7539946`.

Generation 150 starts at 12:46:41 EDT, builds local runtime image
`sha256:2214fe3e88396658fd7fa299f0deb4462b788d6aca288961091eac21f200f6bf`, publishes registry
manifest `sha256:91cb4717bd04897300f6a975909cb8ceae7e4b29a6b1b3da46cf24d591f15165`, rolls the
Lifecycle Authority and its preceding retained roles, and exits 1 at the expected
rollout-transition config connection timeout before Provider Worker rollout. Generation 151 starts
unchanged at 13:12:37, reuses the exact identities, reads back the current Authority config, and
rolls Provider Worker Deployment revision 2. Its zero-restart Ready Pod starts at 13:14:25 on
exact local image `2214fe3e...`; the Service and EndpointSlice select `10.42.0.195:8600`. The
first Provider readiness dispatch again returns exact `HttpTimeout \"connection timeout\"`, while
the diagnostic emits no `socket-ingress` event. Postflight at 13:16:40 proves the Service endpoint
remained Ready and exposes the exact deny: `provider-worker-isolation` admits port `provider` only
from namespace `provider-worker`, excluding the Lifecycle Authority caller. This locates the
refusal before the owned route and closes the diagnostic sprint. Stable counterexample
`PROVIDER-WORKER-LIFECYCLE-AUTHORITY-INGRESS-DENIED-2026-08-31` is registered separately under
Sprint `2.130` before the policy changes.

### Remaining Work

None.

## Sprint 2.130: Admit Exact Lifecycle Authority Provider-Worker Ingress [✅ Done]

**Status**: Done — exact Provider ingress is locally and live read-back validated.
**Implementation**: `charts/provider-worker/templates/networkpolicy.yaml`; rendered-policy
regression in `test/unit/ControlPlaneProviderWorkerExecution.hs`.
**Deployment qualification**: proven on the owned ingress surface — Generation 152 reads back the
exact peer without widening the Provider Worker listener. The distinct reciprocal egress omission
is registered under Sprint `2.131` before correction.
**Independent Validation**: a rendered-policy regression requires exactly the Lifecycle Authority
namespace and Pod identity on the Provider port while retaining the existing Provider Worker
namespace lane and all fenced egress rules.
**Docs to update**: `documents/engineering/lifecycle_control_plane_architecture.md`,
`documents/engineering/lifecycle_reconciliation_doctrine.md`, `DEVELOPMENT_PLAN/README.md`,
`DEVELOPMENT_PLAN/00-overview.md`, and `DEVELOPMENT_PLAN/system-components.md`.

### Objective

Admit the exact retained Lifecycle Authority caller to the fenced Provider Worker Service after
the live request diagnostic proves the current NetworkPolicy drops that caller before socket
ingress.

### Stable Counterexample (2026-08-31)

Generation 151 holds the exact binary, image, Service, ready endpoint, request, and authenticated
transport constant. Provider Worker is Ready at `10.42.0.195:8600`, yet the client reaches the
connection-timeout arm and the new production trace emits no `socket-ingress`. The rendered
`provider-worker-isolation` policy admits the Provider port only from its own namespace, while the
registered caller runs as `prodbox-lifecycle-authority` in namespace `lifecycle-authority`.
Stable counterexample `PROVIDER-WORKER-LIFECYCLE-AUTHORITY-INGRESS-DENIED-2026-08-31` is distinct
from Sprint `2.129`'s behavior-neutral classification.

### Deliverables

- Add one ingress peer selecting namespace `lifecycle-authority` and Pod label
  `app.kubernetes.io/name: prodbox-lifecycle-authority` on the existing named Provider port.
- Preserve the namespace-local Provider Worker ingress lane, default-deny posture, Service/Pod
  selectors, every egress fence, authenticated role transport, readiness, replay, and timeout.
- Add source/rendered-policy coverage that fails if the exact caller identity is absent or widened
  to an unrestricted namespace or Pod set.
- Deploy through the unchanged supported reconcile and register any later distinct refusal before
  changing its behavior.

### Validation

1. The focused policy regression proves the exact namespace-plus-Pod ingress identity and existing
   namespace-local lane, with no unrestricted Provider-port peer.
2. Focused and complete local suites, documentation/diff gates, and canonical `prodbox dev check`
   pass.
3. A supported live reconcile reads back the exact ingress identity and either crosses the
   registered timeout or registers a later distinct boundary before behavior changes.

### Current Validation State

The rendered policy has exactly two Provider-port peers in one rule: the retained namespace-local
lane and the Lifecycle Authority namespace joined to the
`app.kubernetes.io/name: prodbox-lifecycle-authority` Pod selector. Every prior egress rule and the
named port remain exact. The focused Provider Worker/policy suite passes **26/26**, the primary
suite **4754/4754**, and auxiliaries **27/33/33**. Documentation/diff, repository policy,
Fourmolu, HLint (`No hints`), warning-clean all-target compilation, and canonical `prodbox dev
check` pass. The executable is unchanged and exact at
`sha256:7ba6d449b9a80ef1ef61002f4498301f59f22172348e71b3e6208577b7539946`. Supported live
Generation 152 starts at 13:41:01 EDT with the same binary, local image `2214fe3e...`, registry
manifest `91cb4717...`, Ready zero-restart Provider Pod, and endpoint `10.42.0.195:8600`.
NetworkPolicy generation 2 reads back the exact new ingress peer alongside the unchanged local
lane and egress fences. The first dispatch still reports connection timeout with no
`socket-ingress`; postflight at 13:44:28 proves the remaining deny is distinct and reciprocal:
`lifecycle-authority-isolation` has no Provider Worker egress entry. Stable counterexample
`PROVIDER-WORKER-LIFECYCLE-AUTHORITY-EGRESS-DENIED-2026-08-31` is registered under Sprint `2.131`
before that policy changes.

### Remaining Work

None.

## Sprint 2.131: Admit Exact Lifecycle Authority Egress to Provider Worker [✅ Done]

**Status**: Done — exact reciprocal NetworkPolicy and live request crossing are proven.
**Implementation**: `charts/lifecycle-authority/templates/networkpolicy.yaml`; exact paired-policy
regression in `test/unit/ControlPlaneProviderWorkerExecution.hs`.
**Deployment qualification**: proven — Generation 153 reads back both exact directional policies,
emits Provider socket ingress, and crosses the registered connection-timeout boundary.
**Independent Validation**: one paired-policy regression requires the Lifecycle Authority egress
destination to join the `provider-worker` namespace and `prodbox-provider-worker` Pod identity on
the existing control-plane port, while the already validated Provider ingress remains exact.
**Docs to update**: `documents/engineering/lifecycle_control_plane_architecture.md`,
`documents/engineering/lifecycle_reconciliation_doctrine.md`, `DEVELOPMENT_PLAN/README.md`,
`DEVELOPMENT_PLAN/00-overview.md`, and `DEVELOPMENT_PLAN/system-components.md`.

### Objective

Admit the retained Lifecycle Authority's exact outbound Provider request to the fenced Provider
Worker after live policy read-back proves the caller's egress policy omits that destination.

### Stable Counterexample (2026-08-31)

Generation 152 holds the exact binary, image, caller/callee Pods, Service endpoint, request, and
authenticated transport constant and reads back Sprint `2.130`'s exact Provider ingress. The same
connection timeout occurs without `socket-ingress`. The Lifecycle Authority policy selects the
source Pod and defaults egress closed, but lists DNS, Kubernetes API, Vault, MinIO, Authority
Backup, Target Agent, and public HTTPS destinations without Provider Worker. Stable counterexample
`PROVIDER-WORKER-LIFECYCLE-AUTHORITY-EGRESS-DENIED-2026-08-31` is distinct from the corrected
callee-ingress omission.

### Deliverables

- Add one Lifecycle Authority egress destination selecting namespace `provider-worker` and Pod
  label `app.kubernetes.io/name: prodbox-provider-worker` on the existing control-plane port.
- Preserve every existing Authority ingress/egress rule, Pod selector, default-deny posture,
  authenticated transport, replay, readiness, request deadline, and Provider policy.
- Extend the exact policy regression across both directional policies so either missing selector
  or any unrestricted peer fails.
- Deploy through the unchanged supported reconcile and register any later distinct refusal before
  changing its behavior.

### Validation

1. The paired-policy regression proves exact namespace-plus-Pod identities in both directions and
   no unrestricted peer on either control-plane port.
2. Focused and complete local suites, documentation/diff gates, and canonical `prodbox dev check`
   pass.
3. A supported live reconcile emits Provider `socket-ingress` and crosses the registered
   connection-timeout boundary.

### Current Validation State

The Lifecycle Authority policy now carries one exact Provider destination joining namespace
`provider-worker` with Pod label `app.kubernetes.io/name: prodbox-provider-worker` on the existing
control-plane port. The paired-policy regression fixes the complete Provider ingress block,
requires the exact reciprocal egress fragment, and pins the Authority control-plane destination
count so an extra broad peer cannot hide beside it. Focused passes **26/26**, primary
**4754/4754**, auxiliaries **27/33/33**, documentation/diff, repository policy, Fourmolu, HLint
(`No hints`), warning-clean all-target compilation, and canonical `prodbox dev check` pass. The
executable remains exact at
`sha256:7ba6d449b9a80ef1ef61002f4498301f59f22172348e71b3e6208577b7539946`. Supported live
Generation 153 starts at 14:04:12 EDT with the unchanged binary, local image `2214fe3e...`,
registry manifest `91cb4717...`, and Ready endpoint `10.42.0.195:8600`. Lifecycle Authority
NetworkPolicy generation 2 reads back the exact `provider-worker` namespace plus
`prodbox-provider-worker` Pod destination at port 8600; Provider NetworkPolicy generation 2
retains the reciprocal exact caller. The request enters at 14:06:43.921 EDT, completes
authenticated ingress, intent/trust/clock revalidation, narrow-session acquisition, and credential
binding, then starts capability execution. The client crosses connection timeout and reports the
distinct response timeout. The Provider Pod is then OOM-killed at its 112 MiB limit and restarts
once; previous-container evidence ends exactly at `capability-execution/started`. This completes
the sprint and registers stable counterexample
`PROVIDER-WORKER-CAPABILITY-EXECUTION-OOM-112MIB-2026-08-31` under Sprint `2.132` before changing
capacity.

### Remaining Work

None.

## Sprint 2.132: Size Provider Worker Capability Execution [✅ Done]

**Status**: Done — measured capacity correction is local- and live-proven.
**Implementation**: `src/Prodbox/Capacity/Config.hs`,
`src/Prodbox/ControlPlane/ProviderProduction.hs`, `src/Prodbox/Lib/ChartPlatform.hs`, generated
`prodbox-config-types.dhall`, and focused regressions in `test/unit/Main.hs`.
**Deployment qualification**: proven — Generation 155 completes the exact Provider readiness
capability and response path with zero restarts under the corrected envelope.
**Independent Validation**: the typed resource/runtime-memory plans must account for the bounded
Provider Worker process plus its AWS CLI child peak and continue to satisfy host/cluster capacity,
Guaranteed-QoS, finite-schedule, and generated-chart projection lemmas.
**Docs to update**: `documents/engineering/resource_scaling_doctrine.md`,
`documents/engineering/lifecycle_control_plane_architecture.md`, `DEVELOPMENT_PLAN/README.md`,
`DEVELOPMENT_PLAN/00-overview.md`, and `DEVELOPMENT_PLAN/system-components.md`.

### Objective

Give the fenced Provider Worker a measured typed memory envelope that contains its normal
capability execution, including the bounded AWS CLI child, after the live request trace proves the
current 112 MiB cgroup kills the worker at that stage.

### Stable Counterexample (2026-08-31)

Generation 153 holds the exact binary, image, request, policies, Service endpoint, and readiness
state constant. The protected trace completes every stage through credential binding and records
`capability-execution/started`; no later stage is emitted. Kubernetes independently records
`Last State: Terminated`, `Reason: OOMKilled`, `Exit Code: 137` against the exact 112 MiB limit,
and the client reports response timeout rather than connection timeout. Stable counterexample
`PROVIDER-WORKER-CAPABILITY-EXECUTION-OOM-112MIB-2026-08-31` is distinct from both directional
policy omissions.

### Measured Correction (2026-08-31)

The packaged AWS CLI peaks at 74,052 KiB in a disposable runtime-image container; the typed plan
rounds that observation upward to an 80 MiB child slot. The live Provider process is approximately
70 MiB at rest, so the prior 112 MiB cgroup left less than the observed child alone. Five possible
callers exist (four bounded request workers plus the independent readiness observer), but production
now routes every AWS CLI and Pulumi launch through one process-wide permit instead of reserving five
simultaneous heavyweight children and overcommitting the supported host. The resulting nested proof
is `56 MiB heap demand <= 64 MiB heap cap` and
`64 + 16 + 80 + 8 + 8 = 176 MiB <= 176 MiB container limit`; the exact Guaranteed-QoS envelope is
`100m / 176Mi`, and the complete portable standing-workload sum remains exactly
`6130m / 12800 MiB <= 6500m / 12800 MiB`. Generated chart values carry
`+RTS -M67108864 -RTS`. AWS CLI execution has an additional 30-second, 4 MiB stdout, and 1 MiB
stderr physical bound while retaining the request's existing absolute deadline.

Focused runtime-memory/capacity/chart regressions pass **17/17**, including a concurrent physical
permit test and complete default resource-plan compilation. The complete primary unit suite passes
**4758/4758** and auxiliaries pass **27/33/33**. Repository policy, pinned Fourmolu, HLint
(`No hints`), Cabal formatting, warning-clean all-target compilation, generated Dhall schemas,
generated docs, docs drift, binary-sibling config validation, and canonical `prodbox dev check`
pass. The gate-built binary is
`sha256:1c25a5648d10ea2ac5d04b5926ead7a4b73dbe1f29d54b5ef2e46eb4281e1145`. Both installed
integration entrypoints deterministically reproduce Sprint `5.38`'s separately registered
fake-tool projection counterexample at **55/63**; all four environment cases pass, and none of the
eight fixture-setup failures reaches the Sprint-2.132 Provider surface. The supported live
reconcile alone remains before closure. Generation 154 builds local image
`sha256:0e6e645e03c74b41582648160721478278b579379d1861aea556a81e447b44ae` in 1123.7 seconds,
publishes registry manifest
`sha256:cd334b2858cee7f7f8cb7a5529c518c8722f3bf11a209560dbbaf43cbd5057c1`, imports OCI manifest
`sha256:72de7fd0410fdcad2a28c8de10cda0ef33f66f4be9225c6972bfc440bfb1ee26` in 94.1 seconds, and
deletes only the superseded local image `sha256:2214fe3e...`. It rolls Lifecycle Authority
generation 30 to a zero-restart Ready Pod, then exits at the expected rollout-transition config
timeout before the Provider Worker resource projection. Unchanged Generation 155 is next.

Generation 155 reads back the in-force config and deploys Provider Worker generation 3 on image
`sha256:0e6e645e03c74b41582648160721478278b579379d1861aea556a81e447b44ae` with the exact
`100m / 176Mi` request/limit, `+RTS -M67108864 -RTS`, zero restarts, no prior termination, and 52
MiB observed after the request. The protected trace enters at 19:56:04.557Z, completes capability
execution at 19:56:14.869Z, completes authority projection and response encoding, and records
socket completion at 19:56:14.960Z. The prior OOM boundary is therefore absent and the complete
Provider-owned response path is live-proven. The caller's remaining response timeout is a distinct
transport-budget counterexample registered under Sprint `2.133`.

### Deliverables

- Measure the Provider Worker and AWS CLI child peak from the live failure and the existing typed
  runtime-memory/capacity model; update the single owning plan rather than hand-editing chart
  resources.
- Preserve one replica, `Recreate`, Guaranteed QoS, finite child schedule, request deadline,
  authenticated transport, replay, Vault credential binding, exact policies, and Provider result.
- Extend focused capacity/projection tests so the prior 112 MiB envelope cannot return and the
  complete default plan still fits the supported host and cluster.
- Deploy through the unchanged supported reconcile and register any later distinct refusal before
  changing its behavior.

### Validation

1. Typed resource and runtime-memory tests prove the exact Provider Worker envelope contains its
   bounded child peak and remains within the complete host/cluster budget.
2. Focused and complete local suites, documentation/diff gates, and canonical `prodbox dev check`
   pass.
3. A supported live reconcile completes capability execution without an OOM restart and advances
   beyond the registered response-timeout boundary.

### Remaining Work

None.

## Sprint 2.133: Align Provider Transport With Bounded Capability Schedule [✅ Done]

**Status**: Done — the stable counterexample is closed locally and by unchanged-command live proof.
**Implementation**: `src/Prodbox/Capacity/ProviderWorkerBudget.hs`,
`src/Prodbox/Capacity/Config.hs`, `src/Prodbox/ControlPlane/Runtime.hs`, and focused regressions in
`test/unit/Main.hs`.
**Deployment qualification**: proven — unchanged Generation 157 receives and decodes the Provider
response, advances through the remaining cluster reconcile, and exits 0.
**Independent Validation**: a focused pure regression proves the Provider HTTP response budget
contains the complete typed child schedule plus bounded protocol overhead while unrelated clients
retain their existing budgets; focused/full suites and canonical `dev check` remain the local gate.
**Docs to update**: `documents/engineering/lifecycle_control_plane_architecture.md`,
`documents/engineering/resource_scaling_doctrine.md`, `DEVELOPMENT_PLAN/README.md`,
`DEVELOPMENT_PLAN/00-overview.md`, and `DEVELOPMENT_PLAN/system-components.md`.

### Objective

Give only the Lifecycle Authority's Provider Worker client a finite response budget that contains
the Provider's already-typed finite capability schedule and bounded response overhead, without
weakening authentication lifetime, replay, server execution bounds, or any other role's transport.

### Stable Counterexample (2026-08-31)

Generation 155 holds image, policy, identity, request, and Provider schedule constant. The
zero-restart 176 MiB Provider enters at 19:56:04.557Z, completes capability execution at
19:56:14.869Z, and completes its socket write at 19:56:14.960Z. Lifecycle Authority nevertheless
reports `HttpTimeout "response timeout"`: its `providerClient` is constructed with the generic
10-second `defaultHttpConfig`, so the observed 10.40-second response crosses that client-only
budget even though the typed child schedule permits at most five minutes. Stable counterexample
`PROVIDER-WORKER-RESPONSE-AFTER-DEFAULT-HTTP-DEADLINE-2026-08-31` licenses only the Provider
transport-budget correction.

The correction is now code-local: one capacity-level budget owns the 300-second maximum child
deadline and a 30-second bounded protocol margin, yielding a 330-second Provider-only HTTP timeout.
The default Provider profile consumes the shared maximum, capacity validation rejects 300,001 ms,
and Lifecycle Authority alone replaces `defaultHttpConfig` on its Provider client. The generic
ten-second default and every sibling client remain unchanged. Focused runtime-memory/transport
regressions pass **18/18**. The complete primary unit suite passes **4759/4759** and auxiliaries
pass **27/33/33**. Generated schemas/docs/config, documentation/diff, repository policy, pinned
Fourmolu, HLint (`No hints`), Cabal formatting, warning-clean all-target compilation, and canonical
`prodbox dev check` pass. The exact gate-built binary is
`sha256:3895099483b8a08616bde0ef734a8168cdee913622313c59c2cdea6778931a2b`.

Generation 156 builds local image
`sha256:d15dc2f66ec1d3707dd257265ab4ccbb98977590049f9db735da2cc97455d5b9` in 1138.6 seconds,
publishes registry manifest
`sha256:0c7dcb853832b998ea3aed9911c5edd3b0b5e12e87a059961389a9632aa1f76c`, imports OCI manifest
`sha256:923b10116be83f05fb1678a8efd29d39f1a444172f2ec3719111fbfd90c4cee0` in 88.6 seconds, and
deletes only Generation 154's superseded local image. It rolls Lifecycle Authority onto the new
runtime and exits at the expected rollout-transition config observation timeout. Unchanged
Generation 157 must read back that config and prove the Provider response completes without the
former generic ten-second client timeout.

Generation 157 repeats the supported command unchanged, reuses the exact local image, registry
manifest, and containerd import, and reads back the current Lifecycle Authority config. Provider
Worker deployment generation 4 is Ready with zero restarts and no prior termination on image ID
`sha256:d15dc2f66ec1d3707dd257265ab4ccbb98977590049f9db735da2cc97455d5b9`; its request and
limit remain exact at `100m / 176Mi`, with `+RTS -M67108864 -RTS`. The protected request enters at
21:00:44.290Z, completes capability execution at 21:00:51.946Z, and records socket completion at
21:00:51.950Z. Lifecycle Authority receives the response, the command advances through Gateway and
TLS-retention, and the complete unchanged reconcile exits 0. The former ten-second Provider-client
deadline is absent and the sprint is live-proven.

### Deliverables

- Derive or validate one Provider-specific finite HTTP response budget against the existing typed
  child schedule rather than changing the generic HTTP default.
- Leave Provider authentication lifetime, replay, response-size bound, physical child permit,
  subprocess bounds, resources, and all non-Provider clients unchanged.
- Add two-sided regressions for containment of the complete child schedule and rejection of a
  timeout at or below that schedule.
- Deploy through the unchanged supported reconcile and register any later distinct refusal before
  changing behavior.

### Validation

1. Focused tests prove the Provider response budget strictly contains its finite child schedule
   and bounded protocol overhead while the generic default remains ten seconds.
2. Complete unit, documentation/diff, and canonical `prodbox dev check` gates pass.
3. An unchanged live reconcile receives and decodes the completed Provider response without a
   client transport timeout.

### Remaining Work

None.

## Documentation Requirements

**Engineering docs to create/update:**

- `documents/engineering/config_doctrine.md` — current boot-field correspondence and no-fallback
  target.
- `documents/engineering/bootstrap_readiness_doctrine.md` — terminal receipt target identity and
  fresh-session migration.
- `documents/engineering/vault_doctrine.md` — exact standing-role target currentness and retained
  receipt admission.
- `documents/engineering/distributed_gateway_architecture.md` — the pre-cutover Gateway consumes
  the configured endpoint without gaining final object-store authority.
- `documents/engineering/lifecycle_control_plane_architecture.md` — retained-local Credential
  Provisioner substrate and explicit one-shot runtime identity.
- `documents/engineering/lifecycle_reconciliation_doctrine.md` — exact substrate observation and
  Job admission preconditions.

**Product docs to create/update:**

- None.

**Cross-references to add:**

- Record the Phase `2` own-surface reopen in [README.md](README.md) and
  [00-overview.md](00-overview.md); register the fallback in
  [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md).

## Related Documents

- [README.md](README.md)
- [00-overview.md](00-overview.md)
- [system-components.md](system-components.md)
