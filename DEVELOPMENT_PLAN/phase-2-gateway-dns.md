# Phase 2: Haskell Gateway Runtime and DNS Ownership

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [00-overview.md](00-overview.md),
[system-components.md](system-components.md), [the engineering doctrine docs](../documents/engineering/README.md),
[pulsar_messaging_doctrine.md](../documents/engineering/pulsar_messaging_doctrine.md),
[chaos_hardening_doctrine.md](../documents/engineering/chaos_hardening_doctrine.md),
[distributed_gateway_architecture.md](../documents/engineering/distributed_gateway_architecture.md),
[pure_fp_standards.md](../documents/engineering/pure_fp_standards.md),
[resource_scaling_doctrine.md](../documents/engineering/resource_scaling_doctrine.md),
[streaming_doctrine.md](../documents/engineering/streaming_doctrine.md),
[tla_modelling_assumptions.md](../documents/engineering/tla_modelling_assumptions.md)
**Generated sections**: none

> **Purpose**: Capture the Haskell gateway runtime, its formal verification path, the canonical
> Route 53 ownership or update flow, and the CLI-doctrine adoption sprints that align the gateway
> daemon with [Long-Running Daemons in the Same
> Binary](../documents/engineering/README.md).

## Phase Status

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
[00-overview.md](00-overview.md) Alignment Status). Phase 2's gateway-runtime + DNS-ownership surfaces
are thereby home-substrate live-proven (this run also corrected the `gateway-daemon` validation's
`config.dhall` renderer — empty `event_keys`, `vault = None`, `SecretRef`-typed creds — so the host
`gateway status` decodes and queries the live daemon; recorded in [README.md](README.md) Closure
Status). The `--substrate aws` partition-tolerance axis stays a distinct, non-blocking live-infra note
([substrates.md](substrates.md)).

✅ **Reclosed 2026-06-16** — the Vault-root finalization (see [README.md](README.md) Closure Status
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
zero-child-info refinement (see the 2026-06-15 Closure Status in [README.md](README.md) and
[vault_doctrine.md §9](../documents/engineering/vault_doctrine.md)) extends Sprint `2.26`'s custody
surface with the downstream-identity-to-Vault-KV + opaque-namespace deliverable: downstream identity
rides the Model-B object-store as `DownstreamCluster <id>` logical objects, and per-child Kubernetes
namespaces are opaque IDs, so a sealed-parent Kubernetes dump leaks no child name — refines, does not
reverse, the 2026-06-14 model and reopens no new phase. **Prior closure preserved**: ✅ Done on the
code-owned gateway-runtime, DNS-ownership, peer-transport, and daemon-lifecycle surfaces
(Sprints `2.1`–`2.25`); the reclosure detail below is retained verbatim and is unchanged by this
reopen.

✅ **Reclosed on the code-owned surface 2026-06-09** — reopened 2026-06-09 for Sprints `2.24`–`2.25`
(design-intention review; see [README.md](README.md) Closure Status); both have now landed. Sprint
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
finite limits independent of daemon uptime. A per-emitter retained Model-B continuity record
write-ahead-stages the exact signed assertion and next fixed-width anchor before publication; the
separate durable admission marker prevents missing retained state from being mistaken for a fresh
member. Route 53 effects consume a typed credential-and-continuity-authorized action under the
capacity-one child permit, with no ambient AWS authentication path. The
gateway container doctrine is implemented on `ubuntu:24.04` with in-image `ghcup`, pinned GHC
`9.12.4`, no symlinked Haskell tool shims, and the retained in-image AWS CLI bundle. Sprints
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
for the previously landed surface; Sprint `2.31` adds its own bounded-state and transport proofs;
where a validation would touch Route 53, a deployed cluster, an unsealed Vault, or running MinIO,
it is exercised on the home/local substrate or against a stub, and the live-infrastructure exercise
is tracked as a non-blocking `Live-proof: pending` note rather than as `⏸️ Blocked`. Live AWS or
deployed-cluster proof never becomes a backward dependency; a demonstrated defect in this phase's
own runtime, such as the July 10 unbounded-memory counterexample, does reopen the owned surface.

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
[streaming_doctrine.md#at-least-once-event-processing](../documents/engineering/streaming_doctrine.md#at-least-once-event-processing)
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
  [streaming_doctrine.md#at-least-once-event-processing](../documents/engineering/streaming_doctrine.md#at-least-once-event-processing)
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

- None. The code-owned surface closed 2026-06-09 and the home `gateway-daemon`, `gateway-pods`, and
  `gateway-partition` validations were live-proven on 2026-06-26.

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
- Sprint `2.26` extends the registration payload with parent-custodied endpoint inventory,
  kubeconfig reference, account id, and Pulumi stack references. The gateway daemon exposes
  `/v1/federation/children` for metadata-only inventory and
  `/v1/federation/children/<child>/bootstrap` for the child bootstrap credential; both read through
  Vault Kubernetes auth and fail closed when Vault is unavailable.
- The end-to-end opaque Kubernetes namespace/log redaction proof is composed from the Sprint `4.33`
  Haskell-side gate/redaction work and the sealed-state red-team in Sprint `5.8`.

### Remaining Work

- None. Sprint `2.26`'s gateway/CLI custody surface is closed; the Haskell redaction work and home
  sealed-Vault proof subsequently landed under Sprints `4.33` and `5.8`.

### Current Validation State

- `cabal build --builddir=.build exe:prodbox` passes with
  `src/Prodbox/Cluster/Federation.hs` in the library module set.
- `cabal test --builddir=.build test:prodbox-unit --test-options='-p "cluster federation custody"'`
  passes 9/9 after the child index, bootstrap-credential KV, and downstream-inventory additions.
- `cabal test --builddir=.build test:prodbox-unit --test-options='-p "native gateway helpers"'`
  passes 3/3, including the daemon Vault-auth coordinate decode.
- `cabal test --builddir=.build test:prodbox-unit --test-options='-p "parser"'` passes 258/258,
  including the updated generated command examples for `cluster federation register`.
- `cabal test --builddir=.build test:prodbox-integration --test-options='-p "Sprint 2.26"'`
  passes 1/1, proving the built gateway daemon serves the Vault-backed child listing and bootstrap
  credential endpoints without leaking the child token in the list response.
- `cabal test --builddir=.build test:prodbox-integration --test-options='-p "Sprint 4.32"'`
  passes 1/1 after the registration writer records metadata, bootstrap credential, and child-index
  KV objects against fake Vault and fake kubectl without printing the child token.
- `./.build/prodbox test unit` passes 924/924 after accepting the updated generated CLI
  registry/help goldens for the new federation-register inventory flags.
- `./.build/prodbox test integration cli` passes 38/38, including the new Sprint `2.26` gateway
  federation endpoint proof and the existing Sprint `4.32` registration proof.
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

## Related Documents

- [README.md](README.md)
- [00-overview.md](00-overview.md)
- [system-components.md](system-components.md)
