# prodbox Development Plan - Overview

**Status**: Reference only
**Supersedes**: N/A
**Generated sections**: none

> **Purpose**: Provide static plan navigation, phase ownership, historical baselines, and hard
> constraints for the Haskell rewrite of `prodbox`. Current status and resume order live only in
> [README.md → Resume Here](README.md#resume-here).

## Vision

Build a clean-room Haskell `prodbox` repository with:

1. One explicit `prodbox` CLI surface implemented in Haskell.
2. One supported local lifecycle operator environment: `Ubuntu 24.04 LTS` with systemd. This
   Ubuntu-only host gate is generalized to a multi-OS host-provider model (Linux-native, macOS via a
   Lima VM, Windows via a WSL2 distro) per
   [host_platform_doctrine.md](../documents/engineering/host_platform_doctrine.md) — Sprint `1.52`
   landed the host-provider config/detection surface, and Sprint `4.37` landed host-provider ensure
   decisions plus Docker Linux-frame dispatch; everything Docker-inward stays OS-agnostic Linux.
3. One host-owned `prodbox cluster reconcile|delete [--yes|--cascade [--yes]]|status|health|wait|start|stop|restart|logs|workload-logs` surface for
   the local RKE2 cluster, plus the operator-only `prodbox nuke` total-teardown command that
   refuses non-TTY contexts and requires the typed-confirmation literal `NUKE EVERYTHING`.
4. One canonical test suite (the named-validation set in `src/Prodbox/TestValidation.hs`) that
   runs against substrates rather than against separate home-cluster and AWS validation
   surfaces. Substrates today are the home local RKE2 cluster on the operator host and the AWS
   substrate composed of the per-run stack registry entries `aws-eks` (Pulumi stack id
   `aws-eks-test`: EKS cluster + node group), `aws-eks-subzone` (delegated Route 53 subzone), and
   `aws-test` (three `Ubuntu 24.04 LTS` EC2 instances across separate AZs for HA-RKE2). The
   authoritative substrate inventory is [substrates.md](substrates.md).
5. One generated, binary-sibling Tier-0 `prodbox.dhall` as the supported host configuration and
   sealed-Vault bootstrap floor. Its `parameters` payload is decoded directly into Haskell types
   against the generated `prodbox-config-types.dhall` schema; `test-secrets.dhall` is the separate
   test-only plaintext fixture, and no generated JSON artifact exists on the supported path.
6. One host build root `.build/` with the operator-facing binary at `.build/prodbox`, produced by
   the canonical `cabal build --builddir=.build exe:prodbox` invocation followed by a copy step
   that places the binary at the root of `.build/`.
7. One container build root `/opt/build`, owned only by Dockerfiles under `docker/`.
8. One repository-owned custom-image doctrine: every custom Dockerfile needing Haskell builds is
   single-stage from `ubuntu:24.04`, installs `ghcup` in-image, pins GHC `9.12.4`, and does not
   create symlinked Haskell tool shims; the supported public edge does not depend on a
   repository-owned nginx auth-proxy image.
9. One in-cluster `registry:2` steady-state doctrine: direct public-registry pulls are permitted
   only for the registry's MinIO/storage bootstrap dependencies, and every later supported Helm
   deployment pulls from the in-cluster registry.
10. One idempotent post-bootstrap image-reconcile path: after the registry is healthy,
    `prodbox` ensures required public images and all custom images are present in it
    before later deployment.
11. One native-architecture container-build doctrine: `amd64` hosts build `amd64` images, and
    `arm64` hosts build `arm64` images.
12. Native `arm64` container builds work on native `arm64` Docker daemons, while cross-arch
    builds, `docker buildx`, and mixed-arch clusters are unsupported. Native-host-architecture
    publication extends across the macOS (Lima) and Windows (WSL2) host providers — the build runs
    inside the OS-appropriate Linux frame — per
    [host_platform_doctrine.md](../documents/engineering/host_platform_doctrine.md) (Sprint `1.52`
    config/detection surface landed; Sprint `4.37` provider decisions and Linux-frame dispatch
    landed).
13. One retained Lifecycle Authority in the home control plane: it journals idempotent operations,
    fences separately resourced provider workers, and atomically publishes references to immutable
    encrypted Pulumi checkpoint blobs in the generic `prodbox-state` bucket. The AWS substrate
    receives a typed authority client, never a second writer; target Vault delivery uses each
    substrate's separate Target Secret Agent.
14. One in-cluster Haskell gateway runtime with config generation, bounded semantic ownership
    state, bounded HTTP diagnostics, constant-time `/healthz` and `/readyz`, latest-heartbeat
    projection, DNS-write gating, Orders-backed interval validation, HMAC-signed per-emitter
    sequence state, and bounded cursor/delta peer gossip rather than full-log replication,
    runtime claim/yield emission under the `CanWriteDns` gate,
    operator-verifiable bounded-clock-skew enforcement through the supported-host NTP gate and
    `/v1/state` skew reporting, and atomic Orders-promotion coordination keyed off the monotonic
    `orders_version_utc` field. One actor and encrypted identity-bound local journal own every
    emitter transition. The gateway has no bootstrap, lifecycle, provider, object-store, or
    target-secret authority; the minimal Bootstrap Broker, retained Lifecycle Authority, and
    per-substrate Target Secret Agent are separate processes and failure domains.
15. One self-managed public-edge doctrine where MetalLB exposes Envoy Gateway, Kubernetes Gateway
    API owns Layer 7 routes, cert-manager owns listener TLS through one ZeroSSL ACME
    `ClusterIssuer` whose issued certificate is a `LongLived`, registry-managed resource retained
    once in the long-lived `pulumi_state_backend` S3 bucket and restored before every issuance (so
    rebuild cycles restore the certificate rather than re-ordering it against ZeroSSL). Host chart
    orchestration may trigger TLS retain or restore only through the closed Lifecycle Authority
    workflow route; the retained Authority alone authenticates to its state fold, the
    ciphertext-only TLS Retention Adapter, and the exact Target TLS routes, so no operator
    credential can choose a DEK rewrap key or invoke Target materialization directly. Keycloak
    remains the identity provider, every externally reachable app or dashboard lives under the substrate's
    single validated `domain.demo_fqdn`, Envoy enforces Keycloak-backed JWT auth and RBAC on explicit path
    prefixes such as `/vscode`, `/api`, `/ws`, `/auth`, and later supported admin paths, and the
    steady-state request path does not synchronously depend on Keycloak or Redis. Port `80`
    exists only as an HTTP-to-HTTPS redirect into the same shared-host path model.
16. One retained PV host-path model rooted at the configured manual PV root, defaulting to
    `.data/<namespace>/<StatefulSet>/<replica>` — one deterministic PV per StatefulSet ordinal,
    no machine-id prefix, provisioned by a single reconciler.
17. One explicit resource-governance model: host physical capacity, RKE2/kubelet reservations,
    eviction floors, every chart container's cpu/memory/ephemeral-storage request+limit envelope,
    and every durable PVC capacity are declared in the typed capacity plan, and namespace quotas are
    **derived** from the workloads' actual draws rather than authored. The `host ≥ cluster ≥ Σworkloads`
    nesting is an opaque proof-carrying `AllocatedResourcePlan` (Sprint `1.68`): a configuration that
    over-reserves the host, schedules workloads beyond cluster allocatable capacity, or renders an
    uncapped container **cannot be built into a plan** — a non-saturating budget subtraction refuses it —
    and `cluster reconcile` re-proves `cluster ≤ host` against the **observed** host. Runtime memory is a
    separate nested proof: bounded retained state plus maximum heap scratch fits the RTS heap cap;
    the heap cap plus native/non-heap, serialized child-process, kernel/cgroup, and safety reserves
    fits the container limit. External restart/OOM/high-water observation remains required. See
    [resource_scaling_doctrine.md](../documents/engineering/resource_scaling_doctrine.md).
18. Exactly one preserved operator-host directory: `.data/`. Chart secrets, gateway
    peer-event keys, AWS stack outputs, EKS kubeconfig material, and HA-RKE2 SSH key
    material all live inside the cluster (k8s Secrets fetched from Vault KV via Vault
    Kubernetes auth, or Pulumi stack outputs read on demand). The legacy
    `.prodbox-state/` repo-local cache is removed. In-cluster Vault on its durable PV
    under `.data/vault/vault/0` is the persistence anchor for every post-unseal operational secret;
    the password-sealed Tier-1 recovery bundle is the explicit pre-unseal exception. Its KV store
    survives cluster wipes (init-once / unseal-on-rebuild) because the Vault PV is
    retained alongside MinIO's PV under `.data/prodbox/minio/0`. The master-seed
    derivation model is retired — there is no `master-seed` object in MinIO. See
    [Vault Doctrine](../documents/engineering/vault_doctrine.md),
    [Secret Management Doctrine](../documents/engineering/secret_derivation_doctrine.md),
    and [Retained Storage Lifecycle Doctrine](../documents/engineering/storage_lifecycle_doctrine.md).
    Test runs use a separate `.test-data/` retained root and are mechanically forbidden from touching
    `.data/` per [test_topology_doctrine.md](../documents/engineering/test_topology_doctrine.md)
    (Sprint `1.54` schema/preflight and Sprint `5.11` command/isolation work landed).
19. One PostgreSQL doctrine for Helm-managed application data: every supported PostgreSQL
    deployment is external, Percona-operator-backed Patroni HA with exactly three PostgreSQL
    replicas, synchronous replication, and no embedded chart-local PostgreSQL subchart.
20. One supported public workload catalog comprising the cluster-backed `vscode` browser route, a
    JWT-protected API route, a WebSocket route, and the path-routed MinIO operational dashboard,
    all on the same public hostname. The registry has no web UI.
21. One explicit single-host routing model for the public edge:
    `https://<validated-served-fqdn>/<service-path>`, with one public DNS record, one public
    certificate, a port `80` redirect to the HTTPS URL, and no dedicated identity, browser-app,
    API, or WebSocket hostnames.
22. One repo-owned Redis workload path for supported realtime workloads and any later explicit
    external rate-limit service, only as shared application state and never as an Envoy JWT cache.
23. One explicit public-edge transport boundary where public TLS terminates at Envoy, backend HTTP
    remains the current supported workload default, and backend TLS or mTLS requires later
    explicit doctrine ownership.
24. One supported WebSocket connection-lifetime doctrine: auth at connection setup, one live
    upgraded connection pinned to one backend pod until disconnect, reconnect-safe state outside
    the pod, and readiness-based drain before pod exit.
25. One canonical test suite, expressed through named validation commands, with each validation
    described as substrate-agnostic suite content (no substrate-conditional branches in the
    validation logic) and exercised per substrate independently — there is no silent fallback
    between substrates, and a complete canonical-suite proof requires both supported substrates
    to land their own run.
26. One explicit ledger for compatibility or cleanup history that preserves completed removals and
    closes with zero pending supported-path residue.
27. Pulumi retained for true IaC surfaces such as AWS substrate resources, with no supported
    Python Pulumi program and no supported local-cluster public operator flow.
28. One retained-resource preparation rule: lifecycle class controls cleanup, while selected
    capabilities control desired presence. Invite-capable suites submit one revisioned durable
    `aws-ses` operation to the retained Lifecycle Authority, await exact semantic convergence, and
    deliver the committed SMTP generation through retained-home schema-bound custody and the
    selected substrate's Target Secret Agent; ordinary postflight never destroys the long-lived
    provider stack, SMTP identity/generations, or custody receipt.

> **Scheduled doctrine generalizations (2026-07-01 batch — partly implemented).** Structured
> payloads unify on canonical **CBOR** project-wide (the older
> non-CBOR gateway wording is superseded; `cborg`/`serialise` landed for Sprints `2.27`–`2.28`) —
> [pulsar_messaging_doctrine.md](../documents/engineering/pulsar_messaging_doctrine.md). A
> self-maintained native-protocol **Pulsar** client boundary + platform chart, prodbox-as-its-own
> **autoscaler** capacity/scaling with a per-deploy AWS region service-quota gate and mandatory ML
> JIT/model-cache storage budgets
> ([resource_scaling_doctrine.md](../documents/engineering/resource_scaling_doctrine.md),
> [tiered_storage_capacity_doctrine.md](../documents/engineering/tiered_storage_capacity_doctrine.md)),
> typed **cluster topology** (`kind`/`rke2`/`eks`, one compute worker per machine —
> [cluster_topology_doctrine.md](../documents/engineering/cluster_topology_doctrine.md)), the multi-OS
> **host-provider** model, and the **test-topology** `prodbox.test.dhall` SSoT
> ([test_topology_doctrine.md](../documents/engineering/test_topology_doctrine.md)) are scheduled
> across Phases 1–7 (Sprints `2.27`–`2.28`, `3.21`, `1.51`–`1.54`, `4.34`–`4.38`, `5.11`, `7.27`; no
> new phase, Standard E preserved). Sprints `1.51` through `1.54` have landed the capacity/scaling
> schema, multi-OS host-provider config/detection surface, cluster-topology config/schema surface,
> and test-topology schema/topology-mode preflight, and Sprints `2.27`–`2.28` have landed the
> gateway gossip + Orders CBOR codec and durable at-least-once CBOR store. Sprint `3.21` has landed
> the Pulsar CBOR/topic/envelope/chart boundary plus repo-owned Haskell broker
> transport/framing and live broker produce/consume/ack proof; Sprint `4.34` has landed the pure autoscaler planner and
> federation-scoped placement guard; Sprint `4.35` has landed Pulsar topics as managed resources
> with live broker-backed topic reconciliation proof;
> Sprint `4.36` has landed the tiered-storage finite-budget
> planner, autoscaling witness, ML storage totals, and AWS quota preflight adapter; Sprint `4.37`
> has landed host-provider ensure decisions and Docker Linux-frame dispatch; Sprint `4.38` has
> landed substrate-typed one-worker-per-machine placement and anti-affinity; Sprint `5.11` has
> landed the test-topology command surface and `.test-data` isolation; Sprint `7.27` has landed the
> spot-price economics gate and AWS observer surface. Each makes the illegal
> states catalogued in its doctrine doc
> unrepresentable and specifies prodbox as the proven single-node specialization the `~/amoebius`
> umbrella generalizes.

> **Explicit resource guardrails (2026-07-04 reclosure).** The July 4 host OOM incident exposed a
> remaining gap in the capacity doctrine: aggregate budgets existed, but RKE2 guardrails,
> namespace quotas, and chart container request/limit envelopes were not yet mandatory. Phase `1`
> has reclosed on Sprint `1.55`: the Dhall/Haskell config schema now carries
> `capacity.resource_plan` and rejects over-reserved hosts, over-committed quotas, and malformed
> request/limit envelopes before command execution. Phase `3` has reclosed on Sprint `3.22`: chart
> rendering consumes that validated plan, every repo-owned container/init container gets an explicit
> cpu/memory/ephemeral-storage request+limit envelope, root charts render `ResourceQuota` and
> `LimitRange`, and chart lint refuses unbounded templates. Phase `4` has reclosed on Sprint
> `4.41`: `cluster reconcile` writes RKE2/kubelet reservation, eviction, log, and image-GC
> guardrails plus the bounded `rke2-server.service` systemd drop-in, and refuses observed hosts
> below the authored declaration. Phase `5` has reclosed on Sprint `5.13`: the
> `resource-guardrails` canonical validation proves no prodbox pod is `BestEffort`, every checked
> container has cpu/memory/ephemeral-storage requests and limits, root chart namespace
> `ResourceQuota`/`LimitRange` objects match the resource plan, and over-budget configs fail before
> mutation. The optional live stress proof remains a non-blocking Standard O live-proof axis.

> **Resource over-commitment made unrepresentable (2026-07-25 own-surface reopen).** A live
> `test all --substrate home-local` gateway CPU-throttle counterexample — the gateway pinned at its
> 750m limit, ~93% cgroup throttle, periodic RTS heap-overflow — **passed every capacity validation
> yet still failed at runtime**, showing the runtime-`Either` capacity model still lets an illegal
> state be represented. Phase `1` reopened and reclosed on Sprint `1.68` (✅ Done; own-surface, Standard A/N):
> the `host ≥ cluster ≥ Σworkloads` nesting becomes an opaque proof-carrying `AllocatedResourcePlan`
> (total `compileResourcePlan`, matching `ServiceCapacityPlan`/`RuntimeMemoryPlan`) with a
> non-saturating `resourceVectorSubtractChecked`, a `GuaranteedEnvelope` witness, and a `dev check`
> gate that fails the build if `defaultResourcePlan` over-commits. A subsequent full review found the
> proof only gated the *hardcoded default* and that durable/ephemeral storage was a placeholder that
> could drift from the real PVC size, and generalized both into a doctrine
> ([resource_scaling_doctrine.md § 2C](../documents/engineering/resource_scaling_doctrine.md), *one
> value, one proof, unrepresentable over-commit*) with an honest three-ring boundary: **Dhall** is a
> defense-in-depth generator cross-check (no refinement types — now built as the `assertPlanValid`
> lean-emit shim in Sprint `1.72`, so an over-committed `prodbox.dhall` fails to load), the **Haskell
> decode gate** is where over-commit is truly unrepresentable (the proof becomes a required field of
> `ValidatedSettings`, built over the *decoded* in-force plan), and the **observed host** is re-proved
> at reconcile (durable vs ephemeral on distinct devices) and pre-fitted at generate (Sprint `1.73`
> derives a host-fitting `host_capacity`, failing fast when the host is too small). Phase `1` reclosed on **Sprints `1.69`** (the decode gate + draw/allocatable
> projections) **/`1.70`** (`GuaranteedEnvelope` via `WorkloadQoS`); the Phase-3/4 consumers land in the
> order **`3.28`** (one shared `Capacity.Render`) → **`3.29`** (durable PVC size single-sourced from
> `durable_storage_mib`) → **`3.27`** (derived `ResourceQuota`/`LimitRange` via `planNamespaceQuota`/
> `renderedNamespace`/`WorkloadConcurrency`, retiring authored `namespace_quotas`/`concurrentNamespaceQuotas`)
> → **`4.52`** (observed-host dual-device recompile, retiring `hostCapacityCoversPlan` + both
> `clusterAllocatable`). Reconciled: the 3-axis `CapacityBudget` **stays** (live in `Capacity.Storage`/
> `Scaling.Autoscaler`); only unused `MilliCpu`/`MebiBytes` retire. Memory-(c) is already structural via
> `RuntimeMemoryPlan`; CPU demand-(c) stays the non-erasable `uncertified-until-first-profile` seam.
> Sprints `1.68`–`1.70` landed (`src/Prodbox/Capacity/Allocation.hs`, decoded settings proof,
> `WorkloadQoS`, and focused allocation tests); `3.28`/`3.29`/`4.52` are ✅ Done,
> Sprint `1.71` now closes the remaining derivation gap: workload envelopes are projections of
> typed memory, service-capacity, scratch-storage, durable-storage, and topology inputs rather than
> independent authored numbers. Sprint `3.27` consumes that proof for Kubernetes admission. The
> 3-axis `CapacityBudget` **stays**
> (live in `Capacity.Storage`/`Scaling.Autoscaler`); only unused `MilliCpu`/`MebiBytes` retire.
> Sprints `1.72`/`1.73` ✅ Done then build the defense-in-depth Ring-1 layer — the generated
> `prodbox.dhall` carries a baked-in over-commit `assert`, and `config generate` derives a host-fitting
> `host_capacity` from the observed host via the Phase-1-owned `Capacity.HostProbe` reader (shared with
> `4.52`'s Ring-3 reader), closing the live deploy blocked by a fixed 280 GiB default on a 238 GiB host.
> `Deployment qualification: pending` (Standard-P resource-envelope surface).

> **One-shot capacity correction (2026-09-02).** The first current-revision Sprint-`6.5`
> qualification replay found the Bootstrap secret worker absent from the plan: the node carried
> 6945m of requests against 7000m allocatable, so its 250m Guaranteed Pod could not start. Stable
> counterexample `BOOTSTRAP-SECRET-WORKER-ABSENT-FROM-CAPACITY-PLAN-2026-09-02` now fixes the causal
> profile without growing it. The old `1000m / 2048Mi / 10240Mi` host-only RKE2 reservation maps to
> `500m / 1536Mi / 9728Mi` plus the explicit maximum one-shot phase
> `500m / 512Mi / 512Mi`; the total is identical, the gateway envelope is unchanged, and systemd
> retains its prior containment. The plan models one Bootstrap slot and the co-resident
> credential-plus-Target pair as mutually exclusive phases, while all four worker renderers consume
> the same compiled envelope. Qualification state remains solely in [README.md](README.md#resume-here).

> **Runtime-memory correction (2026-07-10).** The July 10 gateway OOM evidence does not invalidate
> those authored-admission and containment lemmas; it invalidates the stronger inference that they
> prove runtime demand. Phases `1`/`2`/`3`/`5` reopened on Sprints `1.60`/`2.31`/`3.25`/`5.16`.
> Sprint `1.60` has reclosed Phase `1` with the nested heap/cgroup budget and generated RTS policy;
> Sprint `2.31` has reclosed Phase `2` with bounded gateway state/transport and credentialed DNS;
> Sprint `3.25` has reclosed Phase `3` with typed/generated constant-time chart probes; Sprint
> `5.16` has landed the external restart/OOM/high-water stability oracle. The longer live stress
> proof remains a non-blocking Standard-O axis, not code-owned work.

> **Emitter retention-leak correction (2026-07-30).** The 2026-07-29 live home deploy reproduced a
> gateway OOM cycle (an `LegacyModelBEmitter` daemon restarting on its ~460 MiB cgroup limit) whose
> mechanism — an unbounded retained-assertion (unacked-suffix) chain — also existed in the Sprint `2.32`
> cutover-target `JournalLeaseEmitter` kernel behind a stalled checkpoint signer. Phase `2` reopened on
> its own runtime surface (Standard A) and reclosed on Sprint `2.37`: the `emitterUnacked` bound moves to
> the live growth point as a hidden-constructor `BoundedUnackedSuffix` (only a fail-closed `appendUnacked`
> grows it), so over-retention is non-constructible, and a `CheckpointFailed` outcome re-emits its exact
> compaction so a stalled signer cannot wedge the suffix. The durable projection format is unchanged
> (byte-compatible). This is code-owned and validated (`dev check` 0); a live long-run leak-free proof of
> the target emitter remains a non-blocking Standard-O axis and `Deployment qualification` stays pending.

> **Retained-SES correction (2026-07-10).** Phases `4`/`5`/`8` reopened on Sprints
> `4.47`/`5.17`/`8.10`: `LongLived` governs cleanup but does not excuse a selected suite from
> ensuring desired presence. Sprints `4.47`/`5.17` have reclosed Phases `4`/`5` with the safe
> registered transaction and capability-derived selected-target plan. Sprint `8.10` reclosed Phase
> `8` on 2026-07-11 with exhaustive semantic readiness and bounded propagation polling. The stack
> remains excluded from ordinary postflight destruction; fresh AWS propagation and deployed
> home/AWS invite aggregates remain non-blocking Standard-O live-proof axes.

> **Daemon-mediated post-bootstrap boundary (2026-07-05).** Phases `2`, `4`, `5`, and `7` have reclosed on
> their owned surfaces. Phase `2` landed Sprint `2.29`: the daemon starts in a pre-Vault mode, binds diagnostics, and exposes
> `POST /v1/bootstrap/vault/ensure` with bounded redacted request parsing, mandatory loopback-proof
> input, in-cluster MinIO/Vault Service access, init/unseal/reconcile orchestration, no standing
> unseal authority, and a host-side `Prodbox.Gateway.Client.ensureVaultBootstrap` call. Phase `4`
> landed Sprint `4.42`: `cluster reconcile` deploys the pre-Vault gateway daemon before root Vault
> bootstrap, `prodbox vault ...` lifecycle leaves prefer the daemon NodePort, and daemon-side Vault
> errors do not fall back to direct host Vault/MinIO transports. Phase `5` landed Sprint `5.14`:
> `daemon-bootstrap` is a named canonical validation whose transport oracle requires daemon
> bootstrap/lifecycle routes, rejects host MinIO port-forward / direct host Vault NodePort /
> host-root-token fallback traces, and checks redaction. Phase `7` landed Sprint `7.30`: Pulumi
> encrypted-backend hydration/store, per-run residue, stack-output reads, and checkpoint prune
> deletes route through the daemon object-store API instead of host MinIO port-forwarding. Existing
> direct host transports are
> tracked only as Pending Removal rows in
> [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md).

> **Unified block storage across substrates (2026-07-02).** EKS moves off dynamic `gp2` to
> **pre-created EBS volumes lifted in as static `Retain` PVs** (CSI `volumeHandle`, AZ-pinned),
> mirroring the home `manual`/no-provisioner model — no dynamic provisioning on either substrate
> ([storage_lifecycle_doctrine.md § 1](../documents/engineering/storage_lifecycle_doctrine.md),
> [cluster_topology_doctrine.md § 4](../documents/engineering/cluster_topology_doctrine.md)).
> Production retains EBS (the analog of `.data/`); suite cleanup selects only test-scoped EBS at
> suite postflight. The target closes that obligation only on exact absence read-back; a failed or
> unobservable reaper remains incomplete. **Current versus target:** Sprint `4.39` landed one
> `aws-ebs-volumes :: LongLived` registry identity, and the legacy reaper distinguished provider
> rows through runtime tags. Sprint `4.84` replaced it with the distinct statically classified
> test-scoped `PerRun` (`aws-ebs-volumes-per-run-test`) and production-retained `LongLived`
> (`aws-ebs-volumes-production-retained`) identities, joined to the typed registry keys by a
> `prodbox dev check` gate; tags remain evidence about the descriptor already selected and never
> choose its class. The legacy reaper's provider-exit completion evidence is unchanged. Sprint `4.39` also landed the typed
> EC2 discover/destroy boundary, retain/test scoped tag markers, and retained-inventory parity;
> Sprint `4.40` has landed the suite postflight test-EBS reaper, retain-safe drain guard, cascade
> hook, and `aws ebs reap-test --yes` recovery
> entrypoint. Sprint `7.28` has landed static EBS PV materialization on the AWS code-owned path
> (CSI renderer, retained EBS ensure loop, AWS chart/bootstrap dispatch, and AZ-pinned node group);
> Sprint `5.12` has landed the code-owned `eks-volume-rebind` validation surface
> (command/planner/body/oracle). The destructive home/AWS live proofs remain non-blocking live-infra
> axes in Sprints `5.12`/`7.28`. The work expands
> each phase's own owned surface (no
> new phase, Standards A/E/N preserved).

> **The terminal audit's field of view is measured (2026-08-17).** The escape audit decides over what
> its tag queries return, so a resource carrying none of the queried tag families is never returned
> and a clean verdict reads exactly like a statement that it is gone. The query catalog's
> completeness was a comment; measuring it against the provisioning programs under `pulumi/` found
> nineteen resources outside the audit's field of view, including every resource of the `aws-test`
> substrate stack and the `aws-eks` cluster, node group, addon, and IAM identities. Sprint `4.84`
> added the `prodbox dev check` join that requires a queried tag on every provider type that accepts
> one, refuses an unclassified type rather than assuming either answer, and enumerates the program
> set from disk so a new program is covered by existing; all nineteen were corrected. Reach is
> classified per type, and the region-dependence of global-service reach is an open ledger row rather
> than a silent assumption
> ([lifecycle_reconciliation_doctrine.md § 6.0](../documents/engineering/lifecycle_reconciliation_doctrine.md#60-the-retained-catalog-is-exact-identities-not-a-tag-predicate)).

The target Vault boundary is the fail-closed KMS/PKI and post-unseal operational-secret root. Its
two explicit non-Vault exceptions are the password-AEAD-sealed Tier-1 recovery bundle needed before
unseal and an ephemeral operator prompt that is never persisted. The initial root token is burned
unused; accessor-audited generated root sessions are short-lived. The Lifecycle Authority
aggregate's generation/digest/reference—not a MinIO blob by itself—is the in-force config SSoT and
selects immutable Transit-enveloped config/checkpoint blobs. Gateway continuity is instead an
encrypted identity-bound local journal and Gateway has no generic object-store authority. The
complete config, Vault, storage, and federation contracts remain in their linked engineering SSoTs;
this plan records only migration ownership and qualification status. Pulumi runs through a
decrypt-to-scratch RAM-tmpfs interposition (its own secrets provider is
dropped) and the long-lived `aws-ses` backend is enveloped uniformly; and the TLS, Keycloak, Pulumi,
and AWS-credential paths fail closed when Vault is sealed. The master-seed HMAC derivation model and its daemon-only seed boundary are
**retired, not wrapped** — `Prodbox.Secret.{Derive,MasterSeed,Inventory}`, the daemon
`/v1/secret/*` RPC, the daemon-only-seed lint, and `selfBootstrapOwnSecrets` are removed, there is
no `master-seed` object in MinIO, and every previously-derived or chart-generated operational secret becomes a
Vault KV object fetched via Vault Kubernetes auth; `FileSecret` / Secret-mounted plaintext Dhall is
**removed, not bridged**. The retained `.data/` PV model, the single ZeroSSL ACME issuer + S3
retain-restore (with key material now Vault-protected), and the managed-resource-registry teardown
all stay. Cluster federation adds a **Vault transit-seal trust tree**: a root cluster whose
password-sealed recovery bundle is consumed only by Bootstrap Broker and zero or more child clusters
(`seal "transit"` against the parent), where each parent owns encrypted child recovery receipts and
revocation attestations—never reusable initial root tokens—and a cluster's downstream inventory is
secret behind an unsealed Vault, so the
fail-closed brick cascades down the tree from the root. The load-bearing invariant: a sealed Vault
reduces prodbox to an opaque durable-data pile — PVs and MinIO objects may still exist, but they
reveal no secrets, no active Dhall, no Pulumi state, and no downstream-cluster inventory until Vault
is unsealed. Adoption is scheduled (each sprint `Done` on its code-owned surface once it builds and
passes local validation, with any live-infra proof tracked as a non-blocking `Live-proof: pending`
axis per [development_plan_standards.md → O](development_plan_standards.md#o-code-local-completion-vs-live-infra-proof))
across the
phases `0`/`1`/`2`/`3`/`4`/`5`/`7`/`8` that own this work — Sprints `0.12`–`0.14`, `1.35`–`1.38`, `2.26`,
`3.17`–`3.20`, `4.29`–`4.33`, `5.8`, `7.14`–`7.15`, and `8.9`. As of 2026-06-16, Phase `1` has
closed Sprints `1.35`–`1.38` on their owned surfaces: the FileSecret-free `SecretRef` contract, the
native `prodbox vault` lifecycle command group, encrypted unlock bundle, sealed-Vault Pulumi gate,
production Vault-Transit `DekCipher`, and the global in-force-config host-loader switch. Runtime AWS
provider credential migration landed in Sprint `7.14`; Vault-sourced ACME EAB/TLS key material
landed in Sprint `7.15`. Phase `3` has reclosed on its owned surfaces: it has the Sprint `3.17` Vault
platform/envelope foundation and the Sprint
`3.18` chart-secret policy/role/service-account plus Kubernetes-auth config and live seed-object
bootstrap foundation;
the `websocket` workload OIDC client-secret is consumed directly from Vault by app-side Kubernetes
auth, and the `keycloak` / `minio` charts materialize their covered runtime secrets through
Vault-login init containers; MinIO admin bootstrap Jobs also read root credentials through
Vault-login init containers; the `vscode` Envoy `SecurityPolicy` client Secret is materialized
from Vault by a chart Job; and gateway event keys plus Route 53 AWS and gateway MinIO credentials
now resolve through Vault Kubernetes auth. Patroni role Secrets are materialized from Vault by the
`keycloak-postgres` pre-install hook using a dedicated `prodbox-<namespace>-pg` ServiceAccount. The
AWS SES SMTP sync writes `secret/keycloak/smtp`, and host/admin helpers read the remaining Keycloak
admin, OIDC, demo-user, and SMTP material from Vault KV. Sprint `3.18` also has the structural
sealed-startup proof that those Vault materializers fail closed on sealed/unreachable Vaults with no
non-Vault fallback. Sprint `3.19` has removed the master-seed derivation modules, gateway
`/v1/secret/*` RPCs, daemon-only-seed lint, self-bootstrap path, and generated-secret assumptions;
Sprint `3.20` has landed the root Shamir / child Transit seal model, recovery-key child init
request shape, Vault chart `seal "transit"` rendering, and parent-owned child init-custody field
map. Sprint `5.8` is `Done` on its code-owned, home-substrate surface: the `sealed-vault` named
validation, planner/parser surface, pure forbidden-pattern oracle, generated Dhall/config SecretRef
sweep, and the live home-substrate sealed-Vault proof all pass. Per
[development_plan_standards.md → O](development_plan_standards.md#o-code-local-completion-vs-live-infra-proof),
the AWS-substrate sealed-Vault red-team exercise of the same validation is a non-blocking
**Live-proof: pending** axis (it needs live AWS spend and the IAM harness simulating the interactive
elevated-credential prompt from the test-harness-only `test-secrets.dhall` fixture
`aws_admin_for_test_simulation.*` so prodbox can mint the dedicated least-privilege `prodbox`
identity into Vault KV); its AWS-substrate coverage is tracked only in
[substrates.md](substrates.md)'s parity table (Standard N), so it never marks Sprint `5.8` or
Phase `5` `⏸️ Blocked` and never reopens Phase `5` for later-phase work.
Sprint `4.29` has landed the root/local cluster lifecycle integration: `cluster reconcile`
deploys/rebinds Vault before MinIO, waits for the Vault StatefulSet, runs init-once/unseal/reconcile,
and `cluster status` / `edge status` surface the Vault seal state while `cluster delete` preserves
`.data/vault/vault/0`. Sprint `4.30` has landed the Model-B object-store foundation:
`Prodbox.Minio.ObjectStore`, `Prodbox.Minio.EncryptedObject`, `prodbox-envelope-v2` hashed stored
AAD, `prodbox-state`, Vault-owned object-store HMAC key material, and the in-force-config read
through the opaque key. Sprint `7.14` has landed the code-owned Pulumi decrypt-to-scratch wrapper
for main per-run and `aws-ses` stack cycles, encrypted stack residue/output reads, first-touch raw
checkpoint migration hooks, and the historical Vault-only AWS provider credential resolution. The
generated operational `aws.*` schema now points only at `secret/aws/lifecycle-provider` through a mandatory
`SecretRef.Vault` reference and setup/teardown mints or clears that operational key in Vault KV
instead of writing plaintext provider credentials to Tier-0 Dhall. The minting interaction happens after Vault is unsealed — the
operator (or the harness simulating the prompt) supplies the ephemeral elevated credential, prodbox
mints the dedicated least-privilege `prodbox` identity, writes the generated `aws.*` straight into
Vault KV, and discards the prompted elevated credential. The test-harness-only
`aws_admin_for_test_simulation.*` fixture is **not** a `SecretRef.Vault` reference and is **not** a
production-config section: it is `TestPlaintext` in `test-secrets.dhall`, read only by the
suite-level IAM harness to simulate that prompt. Bare home
`cluster reconcile` resolves that Vault-backed
operational credential gate before deploying the Route 53-writing gateway daemon; when the object is
absent, it skips the gateway chart cleanly and keeps the local substrate healthy. Sprint `7.14` is
`Done` on its code-owned surface; the remaining live first-touch migration/deletion proof plus the
live both-substrate sealed-state proof are a non-blocking **Live-proof: pending** axis (Standard O)
that needs the IAM harness simulating the elevated-credential prompt from `test-secrets.dhall`
(`aws_admin_for_test_simulation.*`) so the generated operational `aws.*` is minted into Vault KV.
Raw backend env is now confined to `LegacyPulumiBackend` first-touch
import/delete, while supported Pulumi actions receive provider-only input before the scratch
`file://` rewrite.
Those Sprint `7.14` paragraphs preserve the pre-cutover implementation record. The target deletes
the shared `aws.*` path: Lifecycle-provider, Authority-backup, TLS-retention, Gateway-DNS,
per-substrate cert-manager-DNS01, and deterministic `LongLived` SES-SMTP use separate identities
and Target-Agent-delivered generations under Sprints `3.26`, `4.49`, `4.50`, `7.33`, and `8.11`.
The Credential Provisioner derives the region-bound SMTP payload before raw AWS key disposal;
retained-home Agent custody/rewrap restores it cross-substrate without a generic export.
Sprint `5.8` now has the
code-owned `sealed-vault` validation surface, pure audit oracle, and generated Dhall/config
SecretRef sweep closed on its home substrate; the live whole-system sealed-state proof on the AWS
substrate is the non-blocking **Live-proof: pending** axis (Standard O), tracked in the
[substrates.md](substrates.md) parity table rather than as a backward block on Phase `5`.
Sprint `4.33` has closed the
Haskell-side host-disk/k8s/log/oracle gate and redaction surface. The 2026-06-15 Model-B refinement adds the
docs-only Sprint `0.14` and the whole-system Sprint `4.33` (closed 2026-06-16) and reframes
Sprints `1.37`/`4.30`/`7.14` (no new phase reopen). The
single source of truth for the
Vault model is [vault_doctrine.md](../documents/engineering/vault_doctrine.md); the federation trust
tree is
[cluster_federation_doctrine.md](../documents/engineering/cluster_federation_doctrine.md); the
authoritative reopening narration is the 2026-06-14
[README.md → Historical Closure Record](README.md#historical-closure-record) entry (superseding the 2026-06-11 framing for
the derivation model), extended by the 2026-06-13 storage-topology-reorg and the 2026-06-15 Model-B
entries in the same section.

## Test Substrates

Per [development_plan_standards.md → M. Test Suite Substrates](development_plan_standards.md#m-test-suite-substrates),
the canonical test suite is composed of per-substrate runs against both supported substrates.
A substrate is an environment that, for the lifetime of a suite run, stands up the same target
application/platform set: DNS records, TLS certificates, ingress, services, and workload charts.
It provides the prerequisites declared in `src/Prodbox/Prerequisite.hs` and is torn down on suite
exit. The retained local Lifecycle Authority and Provider Worker are a mandatory cross-substrate
dependency outside that duplicated set. The authoritative substrate inventory is
[substrates.md](substrates.md).

Substrate selection is total. Each per-substrate run targets exactly one substrate, consumes
only that substrate's operator-supplied config, and fails fast if any required substrate config
is missing. There is no silent fallback to the other substrate's values. A canonical-suite
proof is complete only when both substrate runs have landed. See
[development_plan_standards.md → M. Substrate coverage and independence (no fallback)](development_plan_standards.md#substrate-coverage-and-independence-no-fallback).

The authenticated `prodbox` command/capability surface is the **exclusive AWS mutation boundary**.
In the target composition, the test harness, explicit stack commands, cascade, and lifecycle
recovery worker are peer clients of the same registered lifecycle-core reconcilers; none is a
second owner or may wrap another's destroy command. Current pre-cutover compositions are named by
the table below. The authoritative target AWS resource inventory and per-resource lifecycle class
(cleanup-managed per-run stacks whose exact obligations are durably registered/scheduled vs
long-lived cross-substrate shared infrastructure retained by design) live in
[substrates.md → Resource Lifecycle Classes](substrates.md#resource-lifecycle-classes).

| Substrate | Provision | Teardown | Status authority |
|-----------|-----------|----------|------------------|
| Home local | `prodbox cluster reconcile` + `prodbox charts reconcile ...` | Current local-only `prodbox cluster delete --yes` preserves LongLived roots and makes no AWS claim. Target `prodbox cluster delete --cascade --yes` is pending Sprint `6.5`, consuming the completed Sprint-`3.41` recovery renderer, Sprint-`5.35` oracle, Sprint-`5.36` descriptor-bound validation client, the Sprint-`4.86` candidate entrypoint that closed 2026-08-20, and the Sprint-`4.89` custodial-capability disposition that closed 2026-08-21. Sprint `4.88` closed the same day: the current cascade no longer takes the local-only no-install short-circuit, so a cascade that reaches no phase exits non-zero, and no cascade exit narrates permission to retire the retained root. | Current parity and deployment qualification live only in [README.md → Substrate Parity](README.md#substrate-parity) and [Deployment Qualification](README.md#deployment-qualification). |
| AWS | `prodbox aws stack eks reconcile` + `prodbox aws stack aws-subzone reconcile` + `prodbox aws stack test reconcile` | Current explicit teardown uses the corresponding `prodbox aws stack <cli-verb> destroy --yes` commands. Sprint `7.36` implements exact independent desired-absence adapters, bounded admin-confirmed/read-back adoption manifests for known pre-manifest stacks, and EKS drain sessions; operational legacy-route removal remains qualification-gated, and LongLived resources remain. | Current parity and deployment qualification live only in [README.md → Substrate Parity](README.md#substrate-parity) and [Deployment Qualification](README.md#deployment-qualification). |

Phase ownership separates suite content (which lives in
[phase-5-canonical-test-suite.md](phase-5-canonical-test-suite.md)) from substrate
provision/teardown and substrate foundations. No phase may own a substrate-specific validation:
validations are suite content and run against every substrate that satisfies their declared
prerequisites.

## Static Phase Dependency Reference

The invariant build direction is numerical: later phases compose earlier phase deliverables and do
not reopen them merely by being incomplete. This reference does not select current work. The only
mechanical queue, including which partially implemented foundations are parked, is
[README.md → Resume Here](README.md#resume-here).

**Phase `0` own-surface reopen, Sprint `0.30` (2026-08-18).** The direction rule above was enforced
by hand audit and had failed twice. Sprint `0.30` re-scoped six items that an earlier sprint held but
could not perform — five in Sprint `4.85`, one owned by nobody — onto the sprints that own the
capabilities they wait on (`5.36`, `6.5`, `7.36`), and made the rule mechanical: `**Blocked by**` and
`**Closure dependency**` are now the only fields that may record a dependency, `Pending Removal` rows
declare a `**Prerequisite**` as data, and `prodbox dev check` fails on a backward entry in either.
The reopen expands Phase 0's own plan-document surface only; it recloses and reopens nothing else.
No sprint status and no queue row changed at the time — Sprint `4.85` remained `Active` on same-phase
work, and the point of the correction was that it became closable by doing that work. It closed the
same day: all eight `OperationalCredentialDispositionBlocker`s are retired and measured, and the queue
advanced to Sprint `4.86`. Details in
[README.md](README.md#resume-here) and Sprint `0.30` in
[phase-0-planning-documentation.md](phase-0-planning-documentation.md).

### Historical clean-room phase record

The phase order below is the forward **build** order — later phases compose earlier deliverables —
**not** a validation gate. Per the phase-independence doctrine
([development_plan_standards.md → N. Phase Independence](development_plan_standards.md#n-phase-independence-and-execution-order)
and [O. Code-Local Completion vs. Live-Infra Proof](development_plan_standards.md#o-code-local-completion-vs-live-infra-proof);
adoption scheduled as Sprint `0.15` in
[phase-0-planning-documentation.md](phase-0-planning-documentation.md)), each phase is validatable
on its owned surface even while any other phase is incomplete, an incomplete later phase never
blocks, gates, or reopens an earlier phase, and the **Independent Validation** column states how
each phase is proven on its owned surface with no dependency on a later phase. Where a validation
would touch a dependency owned by another phase it is exercised against the home/local substrate, a
fake, or a stub; AWS-substrate coverage of suite content is orthogonal and tracked only in
[substrates.md](substrates.md)'s parity table.

**Configuration-ownership expansion (opened 2026-08-22; Phases `1`–`4` reclosed on
`1.92`, `2.52`, `3.42`, and `4.90`).** Phases `1`–`5` reopened only on their own schema/runtime/chart/lifecycle/
harness consumers after an audit found deployment-varying Haskell answers beside decoded Tier-0
fields. Sprint `1.92` removed generated deployment answers and retained the validated context;
Sprint `2.52` removed Gateway's compiled endpoint escape and made absence a typed refusal; Sprint
`3.42` projects the context through all chart consumers and imports the single bucket identity;
Sprint `4.90` binds host/lifecycle observation and execution to the exact context and removes the
remaining endpoint/bucket fallbacks on that surface. Sprint `5.37` closes the harness surface with
explicit fixture/run-derived inputs, complete pre-write validation, and one atomic Tier-0 writer.
Phase-`7` Sprint `7.37` closed the remaining AWS provisioning surface: a validated authored profile
now supplies the Pulumi resource/network envelope and static EBS volume class, while the EKS
topology supplies the positive desired node count. Sprint `7.38` then reclosed Phase `7` by carrying
the optional authored hosted zone through graph compilation and descriptor wire v2, preserving the
zoneless graph identity and restart-reading the superseded zoneless v1 wire. The registered DNS01
family is now decidable from a compiled cascade scope. Stable classification lives in
[config_doctrine.md §0](../documents/engineering/config_doctrine.md#compiled-protocol-constants-versus-operator-supplied-deployment-values);
execution status and order remain only in [README.md → Resume Here](README.md#resume-here).

| Phase | Focus | Prior result | Historical independent validation |
|-------|-------|--------------|-----------------------------------|
<!-- Current corrective status (2026-08-24): Phase 2 is reopened on Sprint 2.75. Sprints 2.70
through 2.74 are reclosed after ready, zero-restart Broker generation 30 crossed exact current-root
absence, post-baseline revocation, corrected post-baseline inventory, corrected
provisioner-accessor cleanup, and provisioner-policy application/read-back unchanged. Its next
protected failure is revoke-provisioner-accessor; boundary-unavailable, so Sprint 2.75 owns that
revocation boundary's exact cause plus the remaining baseline/Authority/handoff path. The retained
generation remains initialized, unsealed, custody-durable, root-session-active, and
handoff-unobserved. Sprint 2.75 is active as of 2026-08-26: its diagnostic-only closed cause is
implemented and its focused, full-unit, authority-suite, documentation-lint, warning-clean, and
canonical development checks pass. Its rollout crossed registry bootstrap, image publication, and
Sprint 3.45's corrected Broker-generation observer. Sprint 2.76's narrow post-revocation LIST 404
correction then crossed live on generation 33, which exposed Sprint `2.77`'s exact provisioner
policy-write HTTP 403 before the provisioner-accessor stage. Sprint 2.77 traced the root-protected
ACL endpoint and implemented a disjoint accessor-free batch repair role for only the provisioner
policy coordinate, with exact read-back and no ordinary-provisioner ACL writes; its complete local
gate passes (**4650** primary plus **27/33/29** authority cases, docs lint, warning-clean all-target
build, canonical development check). Generation 34 then exposed Sprint 2.78's earlier retained
journal admission defect: the old target-list wire decodes, but the store validity predicate
rejects that exact closed receipt before the engine can select its explicit old-target restart.
Sprint 2.78 closed locally and live on generation 35, which entered baseline and exposed Sprint
2.79's distinct pre-mutation identity conflict: production evidence reused the retained ID while
the old-target restart required an advanced ID. Generation 36 live-closed 2.79, ran the restarted
generated-root baseline, and live-closed 2.77 by crossing its exact ACL-policy repair write/read-back.
Sprint 2.80 closed live on generation 37 after the next distinct ordinary provisioner
Kubernetes-auth role HTTP 403. Its correction removes the incomplete `prodbox-*` role glob and derives one exact path per canonical
reconcile role without `sudo` or ACL-policy authority; its focused case, all **4653** primary cases,
the **27/33/29** authority suites, documentation lint, warning-clean all-target build, and canonical
development check pass. Generation 37 runs local image `sha256:ba38284e…`, registry digest
`sha256:d74c7640…`, and containerd manifest `sha256:2ee1cbfc…`, observed and ready 1/1 with zero
restarts. It crossed the role writes/read-backs and named Sprint 2.75's exact live
`http/initial-list-accessors/status-404` cause. Sprint 2.75's local correction admits only that
initial-LIST result as empty, preserves post-LIST 404 and every other refusal, and passes its focused
two-sided case. All **4653** primary cases, the **27/33/29** authority suites, documentation lint,
warning-clean all-target build, and canonical development check pass. Generation 38 runs local
image `sha256:39be376e…`, registry digest `sha256:6bf24c4a…`, and containerd manifest
`sha256:aedc95fd…`, observed and ready 1/1 with zero restarts; it crossed that initial LIST and
registered Sprint 2.81 from the distinct protected `http/post-list-accessors/status-404`
observation before changing it. Generation 39 runs local image `sha256:171956cd…`, registry digest
`sha256:f019969f…`, and containerd manifest `sha256:ad85b11e…`, observed and ready 1/1 with zero
restarts; it crossed Sprint 2.81's correction and registered Sprint 2.82 from the distinct
`prove-provisioner-accessor-absent; boundary-unavailable` observation before changing it. Sprint
2.82's 21-cause diagnostic named exact `http/list-accessors/status-404`; only that role-wide LIST
representation now becomes empty. Generation 41 runs local image `sha256:52e3d111…`, registry
digest `sha256:6be97be0…`, and containerd manifest `sha256:0019b7de…`, with its Broker Deployment
observed and ready 1/1 with zero restarts. It crossed the correction and federated Vault lifecycle,
then the Target Secret Agent exited 1 without a protected startup cause before handoff. Sprint
2.83 is Active and Next on that separately registered diagnostic-first transition. Its local
diagnostic exhausts ten closed startup stages, remains role-local and payload-free, preserves exit
1, and passes its focused 2/2 cases without changing startup behavior. All **4657** primary cases,
the **27/33/29** authority suites, documentation lint, warning-clean all-target build, and the
canonical development check passed before diagnostic deployment. Generation 42 runs local image
`sha256:b8fd8c1a…`, registry digest `sha256:d4b8ce6a…`, and containerd manifest
`sha256:5df3c472…`; its ready, zero-restart Broker crossed baseline and the protected Target Agent
diagnostic named exact `authentication/trust-resolution`. Supported cleanup verified the failed
release absent. The local correction binds only that Agent's standing Vault role to its deployed
`target-secret-agent` namespace instead of `gateway` and passes 3/3 focused cases. Its corrected
complete gate passes all **4658** primary cases, the **27/33/29** authority suites, documentation
lint, warning-clean all-target build, and the canonical development check. Generation 43 runs
local image `sha256:df91ffeb…`, registry digest `sha256:7575c54b…`, and containerd manifest
`sha256:75858447…`; its Broker is observed at 43/43 and ready 1/1 with zero restarts, but the Target
Agent retains broad `authentication/trust-resolution`. Sprint 2.83 remains Active while that broad
cause is refined into typed initial-acquisition, relogin, and Transit-read categories before
another correction. The local refinement is payload-free and passes 4/4 Sprint 2.83 plus 6/6
session-boundary focused cases. Its complete local gate passes all **4662** primary cases, the
**27/33/29** authority suites, documentation lint, warning-clean all-target build, and the canonical
development check. Generation 44 runs local image `sha256:8cfebb18…`, registry digest
`sha256:57d8c3c6…`, and containerd manifest `sha256:f0d3e908…`; its Broker is observed at 44/44,
ready 1/1, and zero-restart, and the refined cause is exact
`authentication/session-acquire/forbidden`. The corrected source role is not live because the
unchanged target enumeration lets the retained closed baseline receipt suppress reconciliation.
The current correction adds the exact Target Agent standing role to required baseline receipt
identity, admits the preceding closed target set only as restart input, and requires a fresh fenced
session. The append-only prior-CBOR migration and fresh-ID proof are implemented; the focused
custody matrix passes 11/11 and the primary suite passes all **4663** cases. The complete gate also
passes the **27/33/29** authority suites, documentation lint, warning-clean
all-target build, and canonical development check. Generation 45 runs local image
`sha256:675fe4d4…`, registry digest `sha256:97de22f4…`, and containerd manifest
`sha256:e9114982…`; its Broker is observed at 45/45, ready 1/1, and zero-restart. The corrected
baseline target identity forces reconciliation, Target Agent session acquisition crosses, and the
next protected cause is broad `handler/boundaries`. The refreshed receipt advances to root session
`root-session-ff34f6c3…`, and supported cleanup verifies the failed release absent. Sprint 2.83 is
closed and live-proven. Generation 46 carries local image `sha256:1aed0098…`, registry digest
`sha256:2c60063c…`, and containerd manifest `sha256:5445d006…`; its diagnostic-only refinement
names exact `handler/boundaries/tombstone-binding`. Production had substituted the independent
deployment cluster ID for the compiled sink identity. The local correction derives the binding
reference from the sink itself; focused startup cases pass 4/4, all **4664** primary cases, the
**27/33/29** authority suites, documentation lint, the warning-clean all-target build, and the
canonical development check pass. Generation 47 carries local image `sha256:e50bbbe4…`, registry
digest `sha256:c94cd668…`, and containerd manifest `sha256:5c1065a6…`. After supported cleanup of
one inherited expired-progress non-proof, its clean-state retry runs the corrected Target Agent
healthy with zero restarts and crosses all handler construction. Sprint 2.84 is closed and
live-proven. Sprint 2.85's diagnostic-only refinement closes
starting/stale plus the five known dependency families' unavailable and identity-rejected states
with `other` fallbacks, discards every underlying detail, and returns the readiness state unchanged;
focused protected-diagnostic cases pass 6/6, all **4666** primary cases and the **27/33/29**
authority suites pass, the warning-clean all-target build passes, and canonical `prodbox dev check`
exits 0. Generation 48 carries local image `sha256:a7ebe0b3…`, registry digest `sha256:7086549e…`,
and containerd OCI manifest `sha256:a80b64c5…`; its Broker is ready 1/1 and its Target Agent runs
healthy with zero restarts. The protected diagnostic names exact
`readiness/dependency-unavailable/target-material`. Helm reaches its progress deadline and supported
cleanup uninstalls the failed release and verifies absence. Sprint 2.85 is closed and live-proven;
Sprint 2.86 was opened because the family still collapsed every compiled target plus the
metadata-read and metadata-validation stages. Its local diagnostic-only refinement now carries a
closed `TargetSecretId` plus one of those two closed stages, preserves the prior readiness
observation for every read/missing/valid/invalid outcome, and rejects arbitrary tokens; focused
protected-diagnostic cases pass 7/7, all **4667** primary cases and the **27/33/29** authority
suites pass, the warning-clean all-target build and documentation lint pass, and a terminal cached
`prodbox dev check` rerun exits 0 after one externally terminated exit-143 non-proof. The
generation-49 diagnostic carries local image `sha256:f5ae7a52…`, registry digest
`sha256:98a85772…`, and containerd OCI manifest `sha256:298d60ac…`; it names exact
`keycloak-patroni-app/metadata-validation`. A field-name-only read through the Agent's standing
identity proves a positive-version, empty-custom-metadata pre-receipt document. Supported cleanup
verifies absence and the retained baseline unchanged. The narrowly readiness-only legacy admission
correction is local: positive-version empty custom metadata is admitted, zero-version empty and
partial metadata remain unavailable, and strict proof/Provider validation is unchanged. Focused
cases pass 7/7, all **4667** primary cases and the **27/33/29** authority suites pass,
documentation lint and the warning-clean all-target build pass, and canonical `prodbox dev check`
exits 0. Generation 50 carries local image `sha256:08d712aa…`, registry digest
`sha256:66bfe597…`, and containerd manifest `sha256:b4a380a9…`; the corrected Target Agent is 1/1
Ready with zero restarts and Sprint 2.86 is closed and live-proven. The same supported reconcile
reaches Lifecycle Authority, whose Pod repeatedly exits 1 without a protected log. Sprint 2.87 is
opened to make that startup failure exact before changing Authority behavior. Its local
35-cause diagnostic closes configuration, typed authentication, exact known primary-store,
coordinate, interpreter, and fallback stages; focused cases pass 9/9, all **4669** primary cases
pass, the **27/33/29** authority suites pass, the warning-clean all-target build passes, and
canonical `prodbox dev check` exits 0 without changing an exit result.
Generation 51 carries local image `sha256:051599eb…`, registry digest `sha256:d20fbc2d…`, and
containerd manifest `sha256:7ea9db67…`. After two explicitly non-proof attempts, the clean retry
executes that image and names exact `authentication/session-acquire/forbidden`; Sprint 2.87 is
closed and live-proven. Sprint 2.88 is Active and Next because the Authority standing role is still
compiled for namespace `gateway` while its exact ServiceAccount is deployed in namespace
`lifecycle-authority`. Its local correction changes only that role namespace, and the focused
standing-role inventory passes all **20** cases while preserving every sibling binding and token
field. All **4670** primary cases and the **27/33/29** authority suites pass, together with the
warning-clean all-target build, pinned formatting/HLint, repository/chart/documentation lint,
generated-document drift check, and clean diff check. The first canonical wrapper attempt is
externally terminated with exit 143 during its Cabal rebuild and is non-proof; its stable rerun
exits 0. Deployment qualification remains. The clean diagnostic retry reaches the 30-minute
deadline with Authority 0/1
Ready and ten restarts; the supported command exits 1 and retains the failed release because the
timeout is non-terminal convergence, leaving the next supported reconcile to own failed-release
handling. That reconcile publishes correction image `sha256:b3ac1a5f…` with registry digest
`sha256:339625c3…` and OCI manifest `sha256:11e846e8…`, but the inherited failed StatefulSet makes
Helm fail before replacing generation 51; the attempt is non-proof, and supported cleanup
uninstalls the release and verifies absence before the clean-state retry. The clean retry executes
that exact image and still reports `authentication/session-acquire/forbidden`, closing Sprint 2.88
on its exact source correction and registering Sprint 2.89 Active and Next: append the Lifecycle
Authority standing role to retained baseline currentness so the old closed receipt cannot suppress
the Vault-role repair. That append-only migration is local; its focused root-session suite passes
all **12** exact-currentness, legacy-codec, fresh-identity/restart, and refusal cases. All **4671**
primary cases and the **27/33/29** authority suites pass, together with the warning-clean all-target
build, pinned formatting/HLint, repository/chart/documentation lint, generated-document drift, and
clean diff checks; canonical `prodbox dev check` exits 0 and deployment qualification remains.
Generation 52 reaches
its 30-minute deadline at 0/1 Ready with 14 restarts; the supported command exits 1 and retains the
release as non-terminal convergence for the next reconcile to own. Sprint 2.89's first deployment
publishes local image `sha256:b5917d5a…`, registry digest `sha256:e735958f…`, and OCI manifest
`sha256:17cc0a57…`; root session `ff34…` advances to `b46b…` and baseline read-back completes. The
inherited failed StatefulSet prevents the new Pod from executing, so rollout is non-proof;
supported cleanup uninstalls the release and verifies absence before the clean-state retry. That
retry runs the exact generation-53 image, crosses the repaired session acquisition, and reports
broad `interpreter/construction`. Sprint 2.89 closes live and Sprint 2.90 is Active and Next to
refine every actual fallible interpreter stage before changing behavior. Its local 21-stage closed
diagnostic passes all **10** focused protected-diagnostic cases without changing an exit result.
All **4672** primary cases and the **27/33/29** authority suites pass, together with the
warning-clean all-target build, pinned formatting/HLint, repository/chart/documentation lint,
generated-document drift, and clean diff checks; deployment qualification remains. The first
canonical wrapper attempt is externally killed with exit 137 during its Cabal
relink and is non-proof; after the build is completed to quiescence, its stable rerun exits 0.
Generation 53 reaches its 30-minute deadline at 0/1 Ready with ten restarts; the supported
command exits 1 and retains the release as non-terminal convergence.
The first Sprint-2.90 deployment publishes local image `sha256:7804e9aa…`, registry digest
`sha256:c6cd242d…`, and containerd OCI manifest `sha256:7e05304d…`; exact baseline read-back
preserves root session `b46b…`. Helm encounters the inherited failed generation-53 StatefulSet
before replacing its `sha256:b5917d5a…` Pod, making the rollout non-proof. Supported cleanup
uninstalls the release and verifies absence. The clean-state retry creates a fresh Pod whose
annotation and runtime image ID both equal `sha256:7804e9aa…`; after kubelet clears a transient
import-induced DiskPressure taint, it reports exact `interpreter/initial-admission`. Sprint 2.90
closes live and Sprint 2.91 is Active and Next to refine registration-coordinate,
corrupt/unready/unobservable observation, and clean-install/migration construction causes before
changing behavior.
Sprint 2.91's six-cause refinement passes all **11** focused protected-diagnostic cases; one prior
unsupported `--match` filter runs no test and is non-proof, while the corrected `--pattern`
invocation exits 0. All **4673** primary cases and the **27/33/29** authority suites pass together
with the warning-clean build, repository-pinned formatter/HLint, docs/drift/diff gates, and a stable
canonical wrapper exit 0. One ambient-formatter rejection and one wrapper ending without a
terminal result during the parallel relink are non-proof. Generation 55 publishes local image
`sha256:15cab9d6…`, registry digest `sha256:1637da9f…`, and containerd OCI manifest
`sha256:58a38ae0…`; baseline read-back preserves root session `b46b…`. Its inherited failed
generation-54 StatefulSet is non-proof, and supported cleanup verifies absence. The clean retry's
Pod annotation and runtime image ID equal the generation-55 local image and report exact
`interpreter/initial-admission/registration-unobservable`. Sprint 2.91 closes live and Sprint 2.92
is Active and Next to distinguish the closed coordinate-authority, native request/HTTP,
missing-version, envelope-open, invalid-Model-B-version, and unknown fail-closed causes without
retaining the underlying detail or changing behavior. That refinement is local and all **12**
focused protected-diagnostic cases pass. All **4674** primary cases, the **27/33/29** authority
suites, warning-clean all-target build, pinned formatter/HLint, docs lint, and diff check pass. The
clean generation-55 reconcile reaches its supported 30-minute deadline at 0/1 Ready with ten
restarts, exits 1, and retains the release as non-terminal convergence. The binary is refreshed and
an unchanged-worktree canonical wrapper rerun exits 0 after one provisional overlapping plan-update
run also exited 0. Generation 56 publishes exact local/registry/OCI identities `sha256:6e121bb0…`,
`sha256:501db8c6…`, and `sha256:0c808831…`; its first reconcile is non-proof because image-import
DiskPressure prevents the replacement Bootstrap Broker from scheduling and stops before Authority.
Collection is limited to superseded untagged prodbox runtime images and recoverable build cache;
free space rises from 25 GiB to 92 GiB, kubelet clears its own taint, and the Broker becomes Ready.
The next supported reconcile reproduces all three generation-56 identities, preserves root session
`b46b…`, and reaches the inherited terminal-failed Authority revision. Its Pod has the new runtime
image ID but the old rollout annotation and is non-proof; supported cleanup uninstalls the release,
verifies absence, and exits 1. The clean retry's Pod annotation and runtime image ID both equal the
generation-56 local image and its protected event reports
`interpreter/initial-admission/registration-unobservable/store-http`. Sprint 2.92 closes live;
the supported reconcile reaches its 30-minute deadline at 0/1 Ready with ten restarts, exits 1,
and retains the release as non-terminal convergence.
Sprint 2.93 is Active and Next to distinguish the response status class without exposing response
body/detail or changing behavior. Its six-way closed native status refinement is local; all **15**
focused protected/native cases, all **4677** primary cases, and the **27/33/29** authority suites
pass. The warning-clean all-target build, pinned formatter/HLint, docs lint, and diff check pass;
the stable unchanged-worktree canonical gate also exits 0. Its HLint memory peak temporarily
crosses kubelet MemoryPressure, so replacement local workloads await kubelet-owned recovery before
deployment; this is pre-deployment non-proof. Kubelet clears the condition, and the supported
recovery reconcile restores MinIO/Vault/Registry before publishing exact generation-57
local/registry/OCI identities `sha256:602d2e86…`, `sha256:8593d6c0…`, and `sha256:756561c1…`.
That recovery run unseals Vault, preserves root session `b46b…`, then uninstalls the inherited
terminal-failed Authority release, verifies absence, and exits 1. Its retained generation-56 Pod
is non-proof. The clean retry's Pod annotation and runtime image ID both equal the generation-57
local image and its protected event reports
`interpreter/initial-admission/registration-unobservable/store-http/authorization`. Sprint 2.93
closes live; the supported reconcile reaches its 30-minute deadline at 0/1 Ready with ten restarts,
exits 1, and retains the release as non-terminal convergence. Sprint 2.94 is Active to
distinguish the closed S3 response error-code class
without exposing response detail or changing behavior. Its eight-way closed native S3 refinement
is local and all **18** focused protected/native cases pass; its canonical validation and
deployment remain. All **4680** primary cases, the **27/33/29** authority suites, warning-clean
all-target build, targeted formatter, pinned HLint, docs lint, and diff check pass. The refreshed
canonical gate twice reproduces an approximately 11.7-GiB process peak after conformance:
one run starves RKE2 until it loses its etcd leader lease and returns 1 without a compiler
diagnostic; a second reaches 5 GiB in 36 seconds and is stopped before repeating that failure.
Because RKE2 disables swap, host swap refresh supplies no usable headroom. An explicit major
collection still leaves 9.28 GiB resident after Fourmolu begins, proving the graph remains
reachable. The first isolated retry proves the file/conformance child leaves its parent at 93 MiB,
then the in-process generated-document family grows that parent to 7.67 GiB. Sprint 2.95 is Active
and Next to run all four existing lint leaves through sequential exact child-process lifetimes that
end before the next leaf or the warning-clean build begins. The Haskell leaf's own 9.66-GiB peak is
the second exact cause: 32 lazy finding batches retain their scanned source graphs until final
concatenation. Strictly completing each batch before the next scan reduces that parent to 1.15 GiB;
direct full-tree Haskell lint exits 0 with about 9.7 GiB host memory available. Sprint 2.95 closes
with two focused cases, all **4682** primary cases, the **27/33/29** authority suites, docs/diff,
warning-clean build, and exact canonical gate green. RKE2's PID/restart count and the node's False
MemoryPressure transition remain unchanged across that canonical run. Sprint 2.94 is unblocked and
Next for its exact-image deployment and observed-cause correction. The first supported deployment
publishes generation-58 local/registry/OCI identities `sha256:86493048…`, `sha256:662fd648…`, and
`sha256:6ed78dc3…`. It is non-proof because RKE2 restarts during the image build and the inherited
failed generation-57 StatefulSet prevents replacement of the old Pod. Supported cleanup uninstalls
the release, verifies absence, and exits 1. The clean exact-image retry creates Pod `f1d4cdfc…`
with the exact generation-58 runtime image and reports
`interpreter/initial-admission/registration-unobservable/store-http/authorization/invalid-access-key`.
The dedicated MinIO principal is currently reconciled by a steady-phase step even though Authority
readiness is a transition prerequisite, so Sprint 2.96 is registered to move that credential
reconcile before Authority admission. The supported clean reconcile reaches its 30-minute deadline
at 0/1 Ready with ten restarts, exits 1, and retains the release as non-terminal convergence.
Sprint 2.94 is Done and live-proven; Sprint 2.96 is Active and Next. Its local correction moves the
unchanged unified IAM job before Authority in both anchored substrate plans and into the home
post-unseal transition executor. The exact dry-run order, warning-clean all-target build, all
**4682** primary cases, and the **27/33/29** authority suites pass. The exact canonical gate also
exits 0 without restarting RKE2 or changing the node's False MemoryPressure transition; the
refreshed binary is `sha256:2b8068bb…`. Live deployment remains.
The first corrected live reconcile publishes generation-59 local/registry/OCI identities
`sha256:ab3462a9…`, `sha256:4b64aa38…`, and `sha256:34a45bba…`, then completes the unified MinIO
bootstrap before Authority admission. The inherited failed generation-58 Helm revision makes that
attempt non-proof; supported cleanup uninstalls it, verifies absence, and exits 1. The exact-image
clean retry remains.
The clean retry creates fresh exact-image Pod `d0b1f1af…`, which stays live with zero restarts; its
Vault credential completes a signed MinIO LIST and the bootstrap-handoff KV probe returns the
expected normalized 404. The remaining readiness refusal is a separate foreign-capability probe:
Authority receives HTTP 403 when asked to use the Target-worker child-custody commitment HMAC,
which its runtime does not own. Sprint 2.96 is Done and live-proven on its ordering surface;
Sprint 2.97 is Done on its code-owned surface: Authority readiness now contains exactly the signed
object-store LIST and bootstrap-handoff observation, and its complete local gate is green without a
policy widening. Generation 60 applies that corrected template but exposes stable counterexample
`HELM-RETRY-2026-08-28`: the chart platform starts a new upgrade from the terminal failed
generation-59 release, after which the StatefulSet retains the unready old ordinal while reporting
generation 60 only as its update revision. Phase 3 is reopened on Sprint 3.46 to reconcile terminal
failed releases to exact absence before a later retry. Generation 61 proves that correction live:
the old release is removed and observed absent, a fresh exact-image Authority Pod becomes Ready,
and handoff completes. Phase 3 is reclosed. The following Authority Backup Pod then proves its Vault
role is still bound to `gateway` rather than `authority-backup`; Provider Worker and TLS Retention
share the stale helper. Phase 2 is reopened on Sprint 2.98 for the exhaustive namespace correction.
Its focused exhaustive standing-role inventory and standing-policy regressions, warning-clean
all-target build, all **4685** primary cases, and the **27/33/29** authority suites are green. The
canonical gate is also green with RKE2 PID `3614880`, zero restarts, and node pressure unchanged;
refreshed binary `sha256:bbc8d886…` is deployed as generation 62. Its local/registry/OCI identities
are `sha256:025367fd…`, `sha256:89c3c57e…`, and `sha256:48f4c027…`; the fresh exact-image Authority
Backup Pod still receives Vault-login HTTP 403 because the closed baseline receipt remains current
when the meaning of an existing target changes. Sprint 2.98 then appends the semantic-revision
target and admits only the exact preceding closed receipt for a fresh generated-root baseline
application. Its focused case and complete **13**-case root-session suite, all **4686** primary
cases, the **27/33/29** authority suites, and the exact canonical gate pass. Generation 63 advances
the retained root session to `root-session-69894281…`; fresh exact-image Authority Backup Pod
`ffab9243…` authenticates to Vault with HTTP 200, receives HTTP 404 only for the not-yet-materialized
backup credential, and revokes the diagnostic token with HTTP 204. Sprint 2.98 is Done and
live-proven. Stable counterexample `AUTHORITY-BACKUP-GENESIS-ORDER-2026-08-28` kept Phase 2
reopened on Sprint 2.99: the Adapter had to be routable before the credential-owning establishment
step, while Helm waited for credential-backed readiness and the process exited while that credential
was absent. Generation 64 closes that cycle: the exact-image Adapter remains Running with zero
restarts and its Helm release remains deployed while the credential is absent, and reconcile enters
establishment. The next refusal is separately registered as
`TOKENREQUEST-MINIMUM-TTL-2026-08-28`: the exact self-token authorization check answers `yes`, but
the operator requests a 300-second TokenRequest below Kubernetes' 600-second minimum. Phase 2 stays
reopened on Sprint 2.100 for a validated lifetime and a validation-versus-authorization rejection
distinction. Generation 65 crosses that correction live: the operator authenticates and receives
the typed missing-generation observation. It then exposes
`PRESEED-SETTINGS-INVERSION-2026-08-28`: Authority Backup establishment asks the steady-state
in-force settings loader for a generation that the deliberately later config-CAS step has not yet
seeded. Sprint 2.100 is Done on its token boundary and Phase 2 remains reopened on Sprint 2.101 to
use the already validated Tier-0 proposal during pre-seed establishment while retaining the
post-CAS in-force loader as the final readiness barrier. That correction is locally complete: its
two focused cases, all **4691** primary cases, the **27/33/29** authority suites, and the exact
canonical gate pass. Generation 66 crosses the settings inversion and enters the Authority Backup
transport. It then exposes `DEAD-PORT-FORWARD-2026-08-28`: no-wait apply returns before the Pod
exists, the Service port-forward exits, and the bounded HTTP loop retries only its dead socket even
after the exact-image zero-restart Pod starts. Sprint 2.101 is Done on its inversion surface and
Generation 67 crosses that dead-child retry boundary, then exposes
`NOT-READY-SERVICE-ENDPOINT-2026-08-28`: the running zero-restart Adapter answers `/healthz` 200
through its Deployment, but its deliberate `/readyz` 503 leaves only a not-ready Service endpoint,
so Service port-forward cannot select it for genesis. Sprint 2.102 is Done and live-proven on its
owned retry boundary; Phase 2 remains reopened on Sprint 2.103 to use the exact Recreate Deployment
as the pre-readiness forwarding coordinate while retaining the Service as the steady ready route.
Generation 68 proves that exact Deployment coordinate against a fresh zero-restart Pod: a read-only
forward observes `/healthz` 200 while `/readyz` remains 503 and the Service endpoint stays not
ready. The supported client nevertheless kills every child before kubectl finishes binding its
socket. Sprint 2.103 is Done and live-proven on routing; Phase 2 remains reopened on Sprint 2.104
for a bounded exact port-forward startup acknowledgement before the first HTTP probe. Generation
69 crosses that acknowledgement and reaches AWS-admin genesis preparation, closing Sprint 2.104
live. Its fifth authenticated Lifecycle Authority request then exceeds the retained replay capacity
of four: three admission observe/begin/confirm entries plus prepare are still live when the
immediate recovery observation arrives. Sprint 2.105 widens that window, migrates the retained
projection, and generation 70 crosses the former request-five refusal. Its next typed response
collapses every prepared-target stage into `target-outbox-unavailable`; Sprint 2.106's diagnostic
then exposes the exact retained journal plan mismatch in generation 71. Sprint 2.107 makes creation
absence-only, and generation 72 adopts the canonical retained plan unchanged before reporting its
expired active-session deadline. Phase 2 remains reopened on Sprint 2.108 for a prepared-only,
pre-attestation renewal CAS that preserves plan and cursor identity.
Generation 73 crosses that renewal and reaches permit-bound Job creation, closing Sprint 2.108.
The fixed `credential-provisioner` namespace and its ServiceAccounts/policies were never installed,
so the Job create fails and exact read-back proves absence. Sprint 2.109 makes that non-secret
execution substrate an explicit read-back-proven pre-genesis component on the mandatory retained
local control plane consumed by both target selections; Generation 78 observes all seven exact
objects and creates the permit-bound Job. Kubernetes then refuses container start because the Pod
declares `runAsNonRoot` without a numeric `runAsUser` while the shared runtime image defaults to
root. Phase 2 remains reopened on Sprint 2.110 to bind both native Credential Provisioner Job
renderers to one explicit nonzero UID/GID/fsGroup projection. Generation 79 is accepted and
scheduled without the former non-root event, but the coordinator's immediate one-shot observation
classifies the legitimate Pending phase as drift and deletes the Pod before kubelet pulls it.
Sprint 2.110 is complete on its code-owned identity projection; Phase 2 remains reopened on Sprint
2.111 for bounded exact Pod convergence before attestation. Generation 80 proves that observer
waits through scheduling, pull, and start, closing Sprint 2.111's owned scope. Its next exact check
then exposes that the permit carries an image-config digest while the `Always` pull is attested by
its registry-manifest identity. Sprint 2.112 binds permit and Kubernetes runtime evidence to that
independently observed manifest digest while preserving the validated pullable tag as an addressing
hint. Generation 82 proves the exact permit/runtime join and reaches attach without identity drift,
closing 2.112. The worker then exits at its closed option parser because the native AWS-admin Job
omits required `--target-worker-image-repository`; Phase 2 remains reopened on Sprint 2.113 for
that argv completeness correction. Sprint 2.113 derives the repository from the validated native
execution reference and passes the exact rendered argv through the production parser. Generation
83 then stops earlier at `prepared-target/outbox/divergent`: the durable outbox may remain one
renewal ahead when publication succeeds before the Authority-state CAS, and a later fresh successor
cannot recover that expired intermediate. Phase 2 remains reopened on Sprint 2.114 for an
expired-only, binding-equivalent outbox-ahead recovery that preserves fail-closed arbitrary-drift
handling. Generation 84 proves that a valid ahead receipt cannot equal its predecessor because the
receipt binds the advancing deadline, selected Agent, and genesis permit kind. Sprint 2.114
then proves the legacy observation omits the advancing image also bound by that receipt, so it
remains open on a bounded migration: authenticated legacy recovery under the strict immutable and
expired-deadline predicate, followed immediately by a complete-intent envelope whose receipt is
always exactly rederived. That implementation is locally green at **27/27** focused, **4711**
primary, **27/33/31** auxiliary, and canonical `dev check`; only its fresh supported deployment
qualification remains. Generation 85 publishes and imports the corrected image but the legacy
object refuses before its migration CAS, proving at least one inferred immutable/deadline predicate
does not describe the retained state. Sprint 2.114 first adds a value-free private discriminator;
it does not weaken the predicate from this generic refusal. That discriminator is locally complete
and classifies only schema, per-binding match/mismatch, deadline relation, and canonical receipt
binding relation. The focused **27/27**, primary **4711**, auxiliary **27/33/31**, and canonical
`dev check` surfaces pass against binary
`sha256:4f6269ef84d78f746d3149d4058fb5748d6eb4e767c23b8cd51e123e98fced3e`; Generation 86 owns the
live observation. It publishes local image
`sha256:06b04569d57a6e890e4e09af77a1b9809937ffcbada11276729f9c8b623bfaef`, registry manifest
`sha256:78775df4c8bb9d3a3a37b7ab970afb4dde2dff48a1b3037a89e870103360b13a`, and containerd OCI
manifest `sha256:6e28bc08a9220ce4e81cfcd58a5f0be262363dbef8bd9ea4520313281021bfbc`, then the private log
reports `schema=legacy renewal=absent`. That falsifies the retained-state premise without weakening
the classifier: Sprint 2.114 closes locally with its exact live fault injection pending, and Phase 2
remains reopened on Sprint 2.115 for the distinct expired non-Prepared attempt. Recovery requires
independent exact old Job/Pod absence and, once authorized, execution-journal absence; deadline
expiry alone is not quiescence.
The first Sprint-2.115 checkpoint adds only a closed phase token and routes both private diagnostics
through the canonical output boundary. Focused **1/1**, AWS-admin **28/28**, primary **4712**,
auxiliary **27/33/31**, and canonical `dev check` pass against binary
`sha256:79be50d53e64a184484bb2e6bb78e570964ba30c1aaa7d82f32d88eea000b0fa`; Generation 87 owns the
constructor observation.
Generation 87 publishes local image
`sha256:0bec934650b5a7aa4707de2b4b7c0e5f57cda6ac6a214121e0cdf70ed743c3d2`, registry manifest
`sha256:4f8012e1b2fbee4675ce3b18cf62fd61b3f7f5decd718a55d10091bfc051953c`, and containerd OCI
manifest `sha256:067d0e596d4bb466d18c339dbd11e6b86c7c29ae86381cfcba058cec4f7b492d`, then identifies the
retained constructor as exactly `authorized`. Sprint 2.115's correction is correspondingly narrow.
The bounded correction is locally green: only an expired exact `Authorized` state plus named Job
404, named Pod 404, and permit-derived journal 404 can mint its opaque proof; a separate GET-only
Kubernetes Role and read-only Vault stanza supply those observations. The injected order is proof,
outbox CAS/read-back, independent outbox read-back, then Authority CAS. Focused **5/5**, AWS-admin
**31/31**, primary **4716**, auxiliary **27/33/31**, and canonical `dev check` pass against binary
`sha256:497b9058f696fe155717da0858555ec68fd09a6da44c5b472e29dded0dbc6f30`.
Generation 88 owns the fresh supported crossing; the installed suite's **8/63** failures remain the
already registered Sprint-5.38 fake-Helm counterexample.
Generation 88 publishes local image
`sha256:bacede1443d0ab5be8480ea5bf93b6b3dd7f5ab0bac3715eb1658b9be2a92bfb`, registry manifest
`sha256:0fa90432116a435dd2fe418dfffb39c725ab3c75654b858e54db00c144cba575`, and containerd OCI
manifest `sha256:8261c3fcfe76945815d9e846dfa47119079e820e9634eeab724287f23b4bf70c`.
The supported run crosses the legacy outbox refusal and fails closed specifically at
`attempt-recovery/journal-unobservable`; live read-only RBAC checks prove the Job/Pod side is exact
and both workload kinds are absent. `AUTHORIZED-JOURNAL-UNOBSERVABLE-2026-08-29` therefore owns a
closed value-free Vault session/request discriminator before any correction.
That discriminator is locally green at focused **5/5**, AWS-admin **31/31**, primary **4716**,
auxiliary **27/33/31**, and canonical `dev check`, against binary
`sha256:a1211a9a12b0875fc986e8ea19fe2dca9f3194b2b7c6930267c4ffa0c75b7230`. It changes no recovery
decision: only KV-v2 404 is absence, every successful value is presence, and all closed
session/request failure tokens remain unobservable until the next supported generation identifies
the live boundary.
Generation 89 publishes local image `sha256:dbd78bc6…`, registry manifest `sha256:1b0466fc…`, and
containerd OCI manifest `sha256:50731bb2…`; fresh Broker and Authority Pods execute that image.
The protected token is exactly `request/unauthorized`, and the configured Authority identity's
self-capabilities allow its known MinIO read while denying a journal-prefix child. The source
policy change was suppressed by a completed root-baseline receipt whose unchanged target inventory
still declares it current. Sprint 2.115 therefore appends one semantic currentness target and
admits only that exact preceding closed receipt through the existing fresh-session restart.
The correction is locally green at Sprint-2.115 **6/6**, root-session **14/14**, and AWS-admin
**31/31**, with primary **4717**, auxiliary **27/33/31**, and canonical `dev check` also passing
against binary `sha256:a8a68e3b1c28b98326c46dbeccc600751eb04cac853578019bd4796a1bdf8adc`:
current construction requires 18 targets, while only the exact preceding 17-target terminal wire
shape may restart under a fresh root-session identity. Generation 90 owns the supported crossing.
Generation 90 publishes local image `sha256:4ac2fcf5…`, registry manifest `sha256:4e419402…`, and
containerd OCI manifest `sha256:231d33c6…`. The root session advances from `69894281…` to
`50cf8517…`; the Authority observes exact journal absence, has the journal read capability, and
executes the recovered worker before cleaning its exact Job/Pod. Sprint 2.115 is done and
live-proven. The next stable counterexample is
`AWS-ADMIN-WORKER-RECEIPT-DECODE-2026-08-29`: successful worker stdout reaches
`AwsAdminWorkerReceiptDecodeFailed`. Sprint 2.116 is Active and Next for a closed value-free
transport discriminator before any decoder change.
That discriminator is locally implemented without changing the captured bytes or decoder result.
It exposes only finite size, raw-decode, terminal-ending, and once-stripped-decode labels; focused
validation passes **1/1**, AWS-admin passes **32/32**, primary passes **4718**, auxiliary authority
passes **27/33/31**, and canonical `dev check` is green against binary
`sha256:4cf6f072f730c4a6515efb60c2e2de30e9432ae3aa2550b5fc70a99a74dd409a`.
Canonical-plus-LF, CRLF, or one other trailing byte is `non-canonical`, not the live
`decode-failed`, so Generation 91 must identify the remaining transport shape before correction.
Generation 91 identifies it exactly: local image `sha256:73eabdaa…`, registry manifest
`sha256:1eed1084…`, and containerd OCI manifest `sha256:83cf84ad…` reach a protected
`size=empty/raw=decode-failed/terminal-ending=absent/without-terminal-ending=not-applicable` token.
`AWS-ADMIN-WORKER-ATTACH-EMPTY-2026-08-29` is the stable refinement. Sprint 2.116 now reads the
same attested Pod/container's already-authorized log only on that empty-success arm, preserves the
old refusal on log-read failure, and sends any retrieved bytes unchanged to the existing decoder.
The fallback is locally complete at Sprint-2.116 **2/2** and AWS-admin **33/33**: non-empty attach
suppresses it, failed log read preserves empty, and successful log bytes remain unchanged. All
**4719** primary cases and the **27/33/31** auxiliary authority suites pass, and canonical
`dev check` is green against binary `sha256:9559725e20e7f42977c72a5518e8c1047f98ea90de90c6ee0ca9688dc388e931`.
Generation 92 publishes local image `sha256:1b07da06…`, registry manifest `sha256:5b110fee…`,
and containerd OCI manifest `sha256:901b9816…`. It reaches the expected empty attach and then a
non-empty Pod log whose exact value-free token is
`size=within-bound/raw=decode-failed/terminal-ending=lf/without-terminal-ending=decode-failed`.
The unchanged public refusal registers stable counterexample
`AWS-ADMIN-WORKER-POD-LOG-DECODE-2026-08-29`; a line-ending correction is disproved, and Sprint
2.116 remains Active for the narrow text-transport correction. That correction is locally complete
at focused **3/3** and AWS-admin **34/34**: worker stdout is a canonical-base64 envelope around the
unchanged receipt; attach accepts it only without an ending, while Pod log accepts it only with the
exact single LF observed in Generation 92. Every other ending/envelope shape refuses. Full local
validation passes at **4720** primary cases plus **27/33/31** auxiliary authority cases, with
canonical `dev check` green against binary
`sha256:d3a908864b2d3469c3fd75a5cea946bd8ea99baf4c30f6c0cb8b62895f5860eb`. Generation 93 owns
the supported deployment crossing.
Generation 93 publishes local image `sha256:81a17414…`, registry manifest `sha256:b0cab68c…`, and
containerd OCI manifest `sha256:a11f1fed…`, reaches the worker, and still refuses. After the exact
Pod-log LF, both the inner receipt and canonical-base64 envelope dispositions are `decode-failed`
and `invalid`, respectively. Stable counterexample
`AWS-ADMIN-WORKER-POD-LOG-ENVELOPE-INVALID-2026-08-29` requires a closed line-topology
discriminator before any line selection or further transport correction.
The discriminator is locally complete at focused Sprint-2.116 **3/3** and AWS-admin **34/34**; it
reports only empty/single/multiple topology and none/unique/ambiguous exact receipt-envelope lines.
It selects nothing. All **4720** primary cases and the **27/33/31** auxiliary authority suites
pass, and canonical `dev check` is green against binary
`sha256:43906c70c9bffd9eed4a21c827ca0e323e6013e033fec0fde7caf766307e991e`. Generation 94 owns the
diagnostic deployment.
Generation 94 publishes local image `sha256:3a1f6d76…`, registry manifest `sha256:150f6b70…`, and
containerd OCI manifest `sha256:885ef30b…`. Its exact refinement is
`line-topology=single/receipt-envelope-lines=none`, followed by the same refusal. Stable
counterexample `AWS-ADMIN-WORKER-POD-LOG-SINGLE-NON-ENVELOPE-2026-08-29` rules out substring
selection and licenses only an explicit record separator plus fixed-version envelope line whose
unique canonical match can be selected fail-closed.
The correction is locally complete at focused Sprint-2.116 **3/3** and AWS-admin **34/34**. Attach
requires exactly the separator plus envelope; Pod log requires the observed final LF and one unique
whole canonical envelope/receipt line. Joined contamination, missing or duplicate matches, CRLF,
and repeated final endings refuse. All **4720** primary cases and the **27/33/31** auxiliary
authority suites pass, and canonical `dev check` is green against binary
`sha256:055567dc5e46bc6fb4099062b6bd8120dc333af4a86181fef0e4f232a5841392`. Generation 95 owns
the supported deployment crossing.
Generation 95 publishes local image `sha256:70db57ca…`, registry manifest `sha256:6b64a1dd…`, and
containerd OCI manifest `sha256:24e86b07…`. Its first three same-source supported attempts do not
reach the AWS-admin worker: the first exhausts the Bootstrap Broker rollout budget; the second
imports the 7.56 GB runtime archive before the registry/MinIO round-trip becomes unreachable while
the retained Ready node carries a temporary import-induced disk-pressure taint; after the node
self-clears that taint, the third crosses baseline reconciliation but finds a stale
Generation-94-annotated Lifecycle Authority Pod resolving the Generation-95 moving tag. That Pod
crash-loops, and the command verifies failed-release cleanup. These are pre-receipt prerequisite
failures, not receipt qualification or a new receipt counterexample; Sprint 2.116 remains Active
for the same exact-image supported crossing from Lifecycle Authority release absence. That
clean-release retry reproduces the registry failure: redundant export/import of the already-current
7.56 GB image crosses the 20 GiB ephemeral-storage floor, evicts registry, and defeats the immediate
post-import probe. Stable counterexample
`LOCAL-RUNTIME-REIMPORT-DISK-PRESSURE-2026-08-29` admits only an exact-current bypass: the same
runtime tag and matching canonical Docker/containerd config digest may skip archive/import; every
absent, mismatched, failed, or malformed observation must still import.
That correction is locally complete. Its two-sided focused table passes **1/1**, all **4721**
primary cases and the **27/33/31** auxiliary authority suites pass, and canonical `dev check` exits
0 against binary `sha256:bf30f402437e4c9920907c2d11f821dbff1a423edffa88662f26e170dc3500a3`.
Generation 96's first attempt performs the required mismatched-image import, stays clear of disk
pressure, and reaches a created-and-cleaned genesis worker, but terminal client output lost to tool
truncation is not receipt evidence. Its unchanged-source retry exposes stable counterexample
`LOCAL-RUNTIME-REIMPORT-CONFIG-MEDIA-TYPE-2026-08-29`: the exact containerd inspection carries the
matching canonical config digest under `application/vnd.docker.container.image.v1+json`, while the
observer recognizes only `application/vnd.oci.image.config.v1+json`, so it incorrectly selects the
mandatory import arm again. The narrow correction recognizes exactly either canonical config media
type, still requires a unique config digest equal to Docker's exact-tag image ID, and keeps all
failed, absent, wrong-tag, malformed, ambiguous, or unequal observations on mandatory import. An
unchanged-source retry returns the expected active-attempt fence
`prepared-target/outbox/divergent`; the deployed value-free diagnostic is exactly
`schema=current renewal=absent`, because Generation 96's first attempt left its new `Authorized`
permit active. The fence is not weakened. The media-type correction is locally complete at focused
**1/1**, primary **4721/4721**, auxiliary **27/33/31**, repository-pinned Fourmolu/HLint `No hints`,
docs/diff checks green, and canonical `dev check` exit 0 against binary
`sha256:56527de2ae835c21c9bb5ae403f6ae412ccfa576525c69a830e356d35dbbf08f`. After the permit expires,
Generation 97 must prove the skip branch live, recover the abandoned attempt through the existing
absence proof, and reach the record-separated receipt boundary.
Generation 97 publishes local image `sha256:b2a58272…`, registry manifest `sha256:f30e8df0…`, and
import manifest `sha256:201762ec…`. The changed-image mandatory import completes in 239.1 seconds
with `DiskPressure=False`; exact absence recovery then reaches a new worker. Attach is empty and the
Pod-log token is again exactly `line-topology=single/receipt-envelope-lines=none`, followed by the
unchanged public `AwsAdminWorkerReceiptDecodeFailed`. Stable counterexample
`AWS-ADMIN-WORKER-POD-LOG-RECORD-ENVELOPE-ABSENT-2026-08-29` requires one closed value-free
discriminator between a malformed fixed-prefix receipt line and a non-receipt worker terminal line;
it licenses neither byte exposure nor another transport correction by inference. An immediate
unchanged-source retry still owns the independent live skip proof while the new permit is active.
That retry prints the exact `RKE2 containerd runtime image already current: ...` token, creates no
archive, performs no import, and stops only at the expected active-`Authorized`
`prepared-target/outbox/divergent` fence; both observer arms are now live-qualified. The next
value-free discriminator is locally complete: none/unique/ambiguous fixed receipt-prefix lines, a
closed 20-constructor worker-terminal cause, and explicit unrecognized/ambiguous arms. Worker errors
lose payloads at their source before entering the Pod log. Focused Sprint-2.116 is **3/3**, the full
AWS-admin group **34/34**, primary **4721/4721**, auxiliary **27/33/31**, pinned Fourmolu/HLint
`No hints`, docs/diff checks green, and canonical `dev check` exit 0 against binary
`sha256:3bd6130bf81d26ac0fe6b9795dec751fadd4a6fcc250c8d892de0ebcf559fb0b`. Generation 98 may deploy
after the retained 10:57:58 EDT permit expires at 11:27:58 and must record the exact closed cause
before any receipt behavior change.
Generation 98 publishes local image `sha256:71b970611f2b8cc664753b47c6ea379aee96474959c5bbae502bffb6ad94de45`,
registry manifest `sha256:d01e5a9fbf4906c7196e8fd4a883318d388f884cc251d427e95ba2a3a1b87929`,
and import manifest `sha256:fd29a7fd54556340f9bd666a886e10ce6c5a98a2fe85a7a834b6fe6ec9c3acef`.
The 239.4-second mandatory import preserves 57 GB free and `DiskPressure=False`; exact recovery
reaches the worker. Attach contains no receipt prefix or terminal line. The Pod log contains no
receipt prefix and exactly `worker-terminal-line=completion-unavailable`, followed by the unchanged
public `AwsAdminWorkerReceiptDecodeFailed`. Stable counterexample
`AWS-ADMIN-WORKER-COMPLETION-UNAVAILABLE-2026-08-29` moves the next investigation to the worker's
closed completion-publication path; it does not license another receipt framing change.
Inspection proves the failure precedes execution: the active worker's delivery resolver reused the
post-revocation completion transport even though the accessor-bearing worker policy intentionally
does not hold that completion signing key. The local correction retains stable caller code 103 as
delivery-only and appends code 104 as completion-only. The active session holds only the delivery
key and Target-observe/intent/retained-delivery routes; the accessor-free batch session holds only
the completion key and AWS-admin completion route. Preparation remains operator/harness-only.
AWS-admin **34/34**, Vault/session **23/23**, primary **4721/4721**, and auxiliary **27/33/31** pass;
pinned Fourmolu/HLint reports `No hints`, documentation/diff checks and canonical `dev check` are
green. Binary
`sha256:6ee36ced07bc4e583902e1a7027ddc35946829e276d703d090b9a5d2479519d3` is the Generation-99
input, admitted after the conservative 12:29 EDT permit-expiry margin.
Generation 99 builds local image `sha256:4501b90e…`, publishes registry manifest
`sha256:b95a04f5…`, and imports containerd OCI manifest `sha256:1e76c8f2…` in 247.6 seconds. Baseline
reconcile incorrectly reuses the retained pre-completion-inventory receipt because no appended
semantic target forces the changed key/policy projection to be applied. Exact-image Lifecycle Authority Pod
`8847825e-b00b-4403-bee8-517e2410a2bd` crash-loops before worker recovery at protected startup
cause `authentication/trust-read/status-403`. Stable counterexample
`LIFECYCLE-AUTHORITY-TRUST-READ-403-2026-08-29` licenses one append-only baseline semantic revision
covering the completion principal/key and derived exact policies; it licenses no capability
widening by inference. The supported command exits 1 after the full 30-minute Helm bound, reports the exact-image
StatefulSet 0/1 Ready with 10 restarts, and correctly retains the failed non-terminal release.
The validated correction appends exactly `BaselineCredentialProvisionerCompletionPrincipal`.
The immediately preceding 18-target closed receipt becomes historical terminal evidence and
restarts under a fresh root session; partial and in-progress predecessor receipts remain refused.
Primary **4722/4722**, focused root-session **15/15**, and auxiliary **27/33/31** cases pass;
pinned HLint reports `No hints`, documentation/diff checks pass, and canonical `prodbox dev check`
exits 0. Binary `sha256:a21c7b64fa42e1e464f02ae2caf741012132f2531e2ac848a1ff6044e77723e9`
is the Generation-100 input. The next supported reconcile must prove a root-session advance from
`root-session-50cf8517…`, Authority readiness without the 403, and live recovery through the exact
delivery/completion split.
Generation 100 publishes local/registry/containerd digests `sha256:5e1cef78…`,
`sha256:5c9d1c5d…`, and `sha256:d806de34…`; baseline read-back advances the root session to
`root-session-3b9d5743…`. The Authority crosses protected startup and recovery reaches the worker,
whose exact Pod-log token is
`receipt-prefix-lines=none/worker-terminal-line=execution-failed`; the public result remains
`AwsAdminWorkerReceiptDecodeFailed`. Stable counterexample
`AWS-ADMIN-WORKER-EXECUTION-FAILED-2026-08-29` requires protected execution-cause diagnosis before
any behavior or capability change. Read-only inspection proves the exact-image Authority is
Running/Ready with zero restarts and the failed worker is cleaned; source inspection proves all
closed execution errors collapse to the one marker. The licensed local change is only an
exhaustive payload-free execution subcause, with no execution, transport, or capability change.
That diagnostic passes AWS-admin **35/35**, primary **4723/4723**, and auxiliary **27/33/31**;
pinned HLint and documentation/diff checks pass, and canonical `prodbox dev check` exits 0. Binary
`sha256:3bf3381e3dd28bb863f5e45a5bea62655c00f2984a3804d4b09ef57a69649071` is the Generation-101
input. Its live crossing must name one exact execution subcause before behavior changes.
Generation 101 publishes local/registry/containerd digests `sha256:c56baffa…`,
`sha256:04f7565c…`, and `sha256:81645f2d…`, retains root session `root-session-3b9d5743…`, then
stops before worker creation: the expired Authorized attempt has a present execution journal, so
no-effect recovery refuses at `attempt-recovery/journal-present`. Stable counterexample
`AWS-ADMIN-AUTHORIZED-RECOVERY-JOURNAL-PRESENT-2026-08-29` requires the exact durable journaled
resume contract; journal presence cannot be laundered into absence or a replacement permit. The
licensed next step is a read-only exhaustive payload-free phase classifier over that exact
permit-derived journal; it preserves corrupt/mismatched/unobservable results as refusals and makes
no journal or recovery mutation.
The classifier passes AWS-admin **35/35**, primary **4723/4723**, and auxiliary **27/33/31**;
pinned HLint and documentation/diff checks pass, and canonical `prodbox dev check` exits 0. Binary
`sha256:e90cb98f4460dad96f13806163f382ef878958f1361a940cb9200e49abca7652` is the Generation-102
input for exact retained-phase observation.
Generation 102 publishes local/registry/containerd digests `sha256:c9b64a3f…`,
`sha256:8dc29aa4…`, and `sha256:04d74efe…`, retains root session `root-session-3b9d5743…` with
read-back digest `a5756119…`, and brings the exact-image Authority Ready with zero restarts. It
creates no credential worker and refuses at `attempt-recovery/journal-present`; the protected
read-only token is exactly `present/intent-committed/initial-attempt`. Stable refinement
`AWS-ADMIN-AUTHORIZED-RECOVERY-INTENT-COMMITTED-2026-08-29` licenses only the exact durable
continuation for that expired permit and intent journal. It does not license journal deletion, an
unrelated replacement attempt, or an inference that provider effects are absent.
The exact continuation is locally complete. With exact Job/Pod absence, authenticated journal
absence or only embedded-permit-equal `intent-committed/initial-attempt` admits the existing
binding-equivalent renewal; all later/remint/corrupt/mismatched/unobservable states refuse. The
old journal remains evidence and access-key creation remains behind the next journal phase.
Focused Sprint-2.116 passes **7/7**, AWS-admin **35/35**, primary **4723/4723**, auxiliary
**27/33/31**, pinned HLint, documentation/diff checks, and canonical `prodbox dev check` pass.
Binary `sha256:81ebde0f6662257bfeacf53b224538cf7cd1310df52e74c37aaa1a61cf2e6002` is the
Generation-103 qualification input.
Generation 103 publishes local/registry/containerd digests `sha256:9db85e6d…`,
`sha256:462dd3c2…`, and `sha256:9f1e75cc…`, retains root session `root-session-3b9d5743…`, and
brings the exact-image Authority Ready with zero restarts. The old
`present/intent-committed/initial-attempt` journal admits a fresh binding-equivalent worker, which
is cleaned after its exact Pod-log token reports `execution-failed/iam-prerequisite-failed`; the
public result remains `AwsAdminWorkerReceiptDecodeFailed`. Stable counterexample
`AWS-ADMIN-WORKER-IAM-PREREQUISITE-FAILED-2026-08-29` licenses only an exhaustive payload-free
subcause derived from `ProductionIamError` before it becomes bounded text, not an IAM behavior,
permission, retry, or capability change.
That diagnostic is locally complete. Every production IAM error constructor has one value-free
class; a native AWS failure adds only its closed authored operation stage and a closed
signing/transport/service/parse/ambiguity class, with explicit unknown fallbacks. Credential and
IAM values, provider messages, request IDs, bodies, counts, and boundary detail cannot enter the
worker terminal line, while provider programs and behavior remain unchanged. Focused
Sprint-2.116 passes **8/8**, AWS-admin **36/36**, primary **4724/4724**, auxiliary **27/33/31**,
pinned HLint reports `No hints`, documentation/diff checks pass, and canonical `prodbox dev check`
exits 0. Binary `sha256:5538a7f75a37685882f283c2eccebcd2cb095dc36cfb784cff6cd83142d05a9e`
is the Generation-104 qualification input. Generation 104 publishes local/registry/containerd
digests `sha256:62beb581…`, `sha256:865155c3…`, and `sha256:a6427e11…`, retains root session
`root-session-3b9d5743…`, and brings the exact-image Authority Ready with zero restarts. The fresh
worker is cleaned after its exact Pod-log token reports
`execution-failed/iam-prerequisite-failed/aws/observe-bucket/service/other-client`; the public
result remains `AwsAdminWorkerReceiptDecodeFailed`. Stable counterexample
`AWS-ADMIN-OBSERVE-BUCKET-SERVICE-OTHER-CLIENT-2026-08-29` licenses diagnosis of only the exact
closed S3 service refusal hidden by `other-client`, not an IAM behavior, retry, permission, or
capability change.
Read-only native STS, bucket-list, and bucket-location probes prove the repository credential is
valid, the configured long-lived bucket is owned, and its `us-west-2` region agrees with config.
The bodyless `HeadBucket` refusal cannot expose an AWS error code; source diagnosis instead finds
that the native S3 signer omitted S3's mandatory `x-amz-content-sha256` header. The narrow local
correction sends and signs the hash of each exact HEAD, GET, or PUT body. Its request-capture test
binds the empty observation body and all five hardening PUT bodies; focused S3 passes **6/6**,
Sprint-2.116 **8/8**, the exact AWS-admin Authority group **36/36**, primary **4725/4725**, and
auxiliary **27/33/31**. Fourmolu is applied, HLint reports `No hints`, documentation/diff checks
pass, and canonical `dev check` exits 0 after 8:56. Binary
`sha256:8755f175a66db556982e7cdb1bc4b9a941c064ac80a6db58ffda6ca4585294b6` is the
qualified Generation-105 input; the gate-built executable is byte-identical to the recorded binary.
Generation 105 builds local image `sha256:d7d89410…` in 991.6 seconds, publishes registry manifest
`sha256:5e8cfd53…`, imports OCI manifest `sha256:48facd99…` in 249.0 seconds, and retains the same
root session/read-back digest. The exact-image Authority is Ready with zero restarts and the fresh
worker is cleaned. The protected terminal advances beyond IAM prerequisite reconciliation to
`execution-failed/target-observation-unobservable`; the public result remains
`AwsAdminWorkerReceiptDecodeFailed`, and the supported command exits 1 after 31:01. Stable
counterexample `AWS-ADMIN-TARGET-OBSERVATION-UNOBSERVABLE-2026-08-29` licenses only diagnosis of
the exact target-observation boundary before a narrow correction, not a retry, capability, target
write, or inference from unobservable state.
Source tracing locates the refusal in the pre-delivery Target read-back. The local diagnostic now
classifies its complete authenticated-provider, endpoint/HTTP transport/status, bounded-response,
response-codec/status, authored remote-refusal, generation/receipt, and retained-custody surface
into a finite payload-free cause before worker terminal rendering. Distinct HTTP 403 bodies collapse
to the same `client/authenticated/transport/http/status/forbidden` token and all client renderings
are unique. The new regression passes **1/1**, focused Sprint-2.116 **9/9**, exact AWS-admin
Authority **37/37**, primary **4726/4726**, and auxiliary **27/33/31**. Fourmolu is applied,
HLint reports `No hints`, documentation/diff checks pass, and canonical `dev check` exits 0 after
10:24. Binary `sha256:ca6cd3af1d46a75ee6ec71ee31f57111d2247a3f5b07559ff4b8bc1b5db5a4dc`
is the qualified Generation-106 input and is byte-identical to the gate-built executable. Its exact
live terminal token must be registered before any behavior correction.
Generation 106 builds/publishes/imports local, registry, and OCI identities
`sha256:b6c7f67e…`/`sha256:e91ae3ed…`/`sha256:f2f94996…`, retains the same root session and
baseline read-back, and brings the exact-image Authority and Target Agent Ready with zero restarts.
No credential worker remains. Expired-Authorized recovery refuses before successor worker creation
at `attempt-recovery/journal-present`; the supported command exits 1 after 30:29.89. Stable
counterexample `AWS-ADMIN-ATTEMPT-RECOVERY-JOURNAL-PRESENT-2026-08-29` licenses only a closed
payload-free refinement of the exact later journal phase and its recovery contract, not arbitrary
presence recovery, remint, journal clearing, inferred target state, or provider replay.
The exact-image Authority's protected log gives the already-authored closed refinement
`present/key-created/remint-used`. Stable refinement
`AWS-ADMIN-ATTEMPT-RECOVERY-KEY-CREATED-REMINT-USED-2026-08-29` requires a predecessor-journal-bound
cleanup-only continuation with stable IAM-key absence before a fresh bounded permit; it does not
permit no-effect classification, journal copying, or mint-before-cleanup.
That cleanup continuation is locally implemented as a distinct normal-worker permit kind carrying
only the exact predecessor signed-permit digest. Its separate journal begins cleanup-required;
stable bounded IAM-key absence is committed before the one remint can prepare a create. The closed
pre-target classifier admits only remint intent, create-attempt prepared, key created, cleanup
required, and cleanup proven; Target-committed, complete, invalid/mismatched, and unobservable
states refuse. The interruption/replay/refusal table passes focused Sprint-2.116 **10/10**, exact
AWS-admin **38/38**, all **4727/4727** primary cases, and the **27/33/31** auxiliary suites.
Fourmolu is applied, HLint reports `No hints`, documentation/diff checks pass, and canonical
`prodbox dev check` exits 0 after 10:24.16. Gate-built binary
`sha256:d77698098ca8f33dc984bf4a0555fee3e230cceaed2c5694be1fd330259c5ea2` is the
Generation-107 input; the supported cleanup-before-mint deployment remains next.
Generation 107 publishes local/registry/containerd identities
`sha256:c7862bba…`/`sha256:26f7e3c1…`/`sha256:7867708c…`, retains the established root session and
baseline read-back, and leaves the exact-image Authority/Target Agent Ready with zero restarts and
no credential worker. Its protected token remains `present/key-created/remint-used`, but recovery
refuses at `recovery-intent-rejected`; the command exits 1 after 32:44.77. Stable counterexample
`AWS-ADMIN-CLEANUP-RECOVERY-PERMIT-KIND-REJECTED-2026-08-29` proves the retained attempt is the
mode-indexed Genesis program while the cleanup kind accepts only normal drafts. The narrow next
step is the same predecessor-bound cleanup-before-remint kind for Genesis while retaining normal;
backup repair stays outside expired-Authorized renewal. The Genesis binding and closed phase set
remain exact.
That correction is locally complete: one closed cleanup program preserves either Genesis or normal
while the permit also binds the exact predecessor signed-permit digest; backup repair and
cross-family substitution remain refused. The Genesis cleanup permit round-trips through the
durable wire and starts its distinct journal at cleanup-required before any remint. Focused
Sprint-2.116 passes **11/11**, exact AWS-admin **39/39**, all **4728/4728** primary cases, and the
**27/33/31** auxiliary suites. Fourmolu, HLint, documentation, and diff checks pass; canonical
`prodbox dev check` exits 0 after 9:06.50. Gate-built binary
`sha256:f85a5338c33c5c8be1276163d5f867a9451e6c28a6ea200388ed665b21501082` is the
Generation-108 input; its supported live reconcile and exact terminal observation remain next.
Generation 108 publishes local/registry/containerd identities
`sha256:83c3fbf9…`/`sha256:8a21c7f6…`/`sha256:28e9fff5…`, retains the established root session and
baseline read-back, and brings the exact-image Authority/Target Agent Ready with zero restarts. The
Genesis cleanup successor crosses the former recovery-intent rejection and emits
`execution-failed/recovery-remint-ambiguous`; the coordinator refuses it as a receipt, the command
exits 1 after 33:03.99, and no worker remains. Stable counterexample
`AWS-ADMIN-CLEANUP-RECOVERY-REMINT-AMBIGUOUS-2026-08-29` requires tracing the exact closed remint
observation before another behavior change; the terminal token alone proves neither cleanup nor a
safe fresh mint.
The terminal cause has one source construction and requires a durably committed
`cleanup-proven/remint-used` phase. Starting from the cleanup successor's mandatory
`cleanup-required/initial-attempt` phase, that proves stable absence before the one remint and a
second stable cleanup after that fresh attempt became ambiguous; it deliberately does not preserve
the ambiguity trigger. No behavior change is licensed or needed. The protected Authority recovery
timestamp is 22:56:23 EDT; after the 30-minute active fence is certainly expired at 23:26:24, the
next action is an unchanged-source supported reconcile that must recover the exact retained phase
before another successor runs.
Generation 109 supplies that proof: the cached same-source image takes the exact-current skip,
retains the same baseline, and the protected Authority log records
`present/cleanup-proven/remint-used` before the successor starts. The successor again emits
`execution-failed/recovery-remint-ambiguous`; the command exits 1 after 1:37.98 and no worker
remains. Stable counterexample
`AWS-ADMIN-CLEANUP-RECOVERY-REMINT-AMBIGUOUS-REPEATED-2026-08-29` makes the next step a diagnostic,
not another blind expiry cycle: distinguish native IAM create dispatch ambiguity, 2xx lost-result
parsing, and the remaining authored cleanup triggers without changing cleanup, remint, retry,
permit, or journal behavior.
That diagnostic is now locally complete and changes no durable wire or recovery behavior. Native
IAM create ambiguity retains only dispatch-ambiguous versus lost-result, while the one-remint
terminal has ten exhaustive value-free triggers spanning journal resume, intent/prepared inventory,
both create ambiguity classes, predecessor/material, and Target delivery/receipt. Sprint-2.116
remains **11/11**, exact AWS-admin remains **39/39**, the generic Credential Provisioner group is
**29/29**, primary is **4728/4728**, and auxiliary authority is **27/33/31**. Fourmolu, HLint,
documentation/diff, and canonical `dev check` pass; the latter exits 0 after 8:56.404. Binary
`sha256:b0cf31db99d2cdda3b79b2b33fca7eb4d2be2eadd39a72021d7d2c7a929764d6` is the
Generation-110 input. The Generation-109 protected timestamp is 23:28:29 EDT, so its active fence
is retained through 23:58:29 and the supported deployment begins only after 23:58:30.
Generation 110 starts after that fence, builds/publishes/imports local, registry, and OCI identities
`sha256:6645b9e5…`/`sha256:985c3a58…`/`sha256:4a6937af…`, and retains the root session and baseline
read-back. Exact-image Authority and Target Agent are Ready with zero restarts; protected recovery
again observes `present/cleanup-proven/remint-used`. The successor terminal is now exactly
`execution-failed/recovery-remint-ambiguous/target-delivery-failed`; the command exits 1 after
33:22.148 and no worker remains. Stable counterexample
`AWS-ADMIN-CLEANUP-RECOVERY-TARGET-DELIVERY-FAILED-2026-08-30` requires source tracing the closed
delivery refusal before changing delivery, authentication, retry, cleanup, remint, permit, or
journal behavior. It proves only that delivery refused and authoritative read-back found no Target
receipt before cleanup.
Source tracing proves no Target-worker Job was created and no Target receipt exists. The locally
complete diagnostic retains only a closed value-free direct-preflight cause, authenticated
Target-intent transport/codec/HTTP/refusal/unavailability/decoder class, exact Target-worker
coordinator constructor, or retained-custody boundary. Explicit other arms and constructor-only
worker projection erase HTTP status integers, private response/Kubernetes detail, identities,
payload/material/receipt values, and retained detail; behavior is unchanged. Focused Sprint-2.116
is **11/11**, exact AWS-admin is **39/39**, generic Credential Provisioner is **29/29**, primary is
**4728/4728**, auxiliary authority is **27/33/31**, Fourmolu is applied, and HLint reports
`No hints`. Both documentation gates and `git diff --check` pass, and canonical `dev check` exits
0 after 8:55.66 with its warning-clean all-target build. Gate-built binary
`sha256:dae7176c20b73a4068ab4570ec6f744a8d6114b8f0bdfc7659d2053e3c42a438` is byte-identical
to `.build/prodbox` and is the Generation-111 input. The Generation-110 protected recovery
timestamp is 00:31:55 EDT, so the active fence is retained through 01:01:55 and no supported
successor starts before 01:01:56.
Generation 111 starts after the fence and builds/publishes/imports local, registry, and OCI
identities `sha256:92001fa1…`/`sha256:0f8017cc…`/`sha256:f6451072…` in 993.3/315.6 seconds.
The immediate registry/MinIO round-trip cannot connect and the supported command exits 1 after
32:25.81 before Authority recovery or a credential worker. Read-only postflight positively proves
the already registered `LOCAL-RUNTIME-REIMPORT-DISK-PRESSURE-2026-08-29`: the Ready node has
`DiskPressure=True` and its NoSchedule taint, eviction events name the ephemeral-storage floor,
registry/control-plane Pods are evicted or Pending, and 28 GiB is free. No new AWS-admin active
fence exists. After automatic pressure recovery, the exact image now retained in Docker, registry,
and RKE2 containerd licenses the unchanged-source exact-current retry and no code change.
Automatic recovery instead stalls at 38 GiB free: kubelet's 10% minimum-reclaim target is additive,
while **15** dangling managed-runtime Docker images retain about 2.88 GB unique each and kubelet
cannot reclaim Docker's separate store. Docker reports 55.97 GB total image data and 51.19 GB
reclaimable; source has no generation-retention step. Stable counterexample
`LOCAL-RUNTIME-DANGLING-IMAGE-RETENTION-2026-08-30` licenses a fail-closed prodbox-owned fold over
machine-formatted dangling inventory for the exact runtime repository, before build and after its
publication/import attempt. Tagged/foreign images, broad prune, build cache, Kubernetes, and the
kubelet floor remain outside the correction.
The local correction runs once in the early host-preflight before RKE2 readiness and again before
and after publication/import. It accepts only canonical full IDs under the exact compiled runtime
repository from `dangling=true` machine rows, deletes them individually without force, and requires
empty read-back; every malformed/duplicate/noncanonical observation or command failure refuses.
Focused Sprint-2.116 is **12/12**, exact AWS-admin **39/39**, generic Credential Provisioner
**29/29**, plan renderers **30/30**, primary **4729/4729**, and auxiliary authority **27/33/31**.
Fourmolu, HLint, both documentation gates, and diff check pass. Canonical `dev check` exits 0 after
8:59.22 with its
warning-clean all-target build. Gate-built binary
`sha256:5718b68d87a11218ec6de1e64da5b1bfd4d64d5f1e90168d67a5145f0cd3fcc7` is byte-identical
to `.build/prodbox`. Generation 112 live-proves the exact selector and deleter: the supported early
host preflight removes exactly all **15** dangling images under the compiled managed-runtime
repository, observes an empty read-back, and touches no tagged or foreign image. Node pressure and
its taint clear, and registry reaches Running/Ready. The command stops before image build at a
32,413,007-microsecond-old `minio` → `registry` admission against the 30-second bound, exits 1
after 1:17.18, and reaches neither Authority recovery nor an AWS-admin worker. No active AWS-admin
fence exists and no admission change is licensed.

The same proof exposes a separate retained-build defect. Docker image data falls to 12.75 GB, but
43.54 GB becomes reclaimable build cache rather than returned storage. Exact image history assigns
**2.87 GB** per generation to the one Cabal build layer, matching the measured 2.88-GB unique
growth; `.build` (921 MB), Cabal package cache (1.2 GB), and Cabal state (539 MB) account for
2.66 GB while the installed binary remains separate. Stable counterexample
`LOCAL-RUNTIME-COMPILE-LAYER-RETENTION-2026-08-30` licenses only deleting those ephemeral outputs
inside the same Dockerfile build `RUN`, after the binary copy. Global build-cache prune, tagged or
foreign image deletion, multi-stage/buildx/cache-mount changes, and removal of the pinned in-image
toolchain remain outside the correction. The implementation is locally qualified: focused
Sprint-2.116 passes **13/13**, primary **4730/4730**, auxiliary authority **27/33/31**, Fourmolu,
HLint (`No hints`), documentation/diff checks, and canonical `dev check` all pass; `dev check` exits
0 after 8:46.200 with its warning-clean all-target build. With no production Haskell change, binary
`sha256:5718b68d87a11218ec6de1e64da5b1bfd4d64d5f1e90168d67a5145f0cd3fcc7` remains
byte-identical to the gate build. Supported image-layer and Target-delivery proof remain.
Generation 113 builds local image `sha256:34531fd4…` in 991.3 seconds, publishes registry
`sha256:d5a18119…`, and imports OCI manifest `sha256:58d4d753…` in 170.3 seconds. Independent
history proves the Cabal layer fell from 2.87 GB to **166 MB** and total image size fell to
**4,831,214,949 bytes**. Managed dangling read-back is empty after the exact predecessor deletion;
Docker build-cache total moves only 50.99 → 51.19 GB while its reclaimable classification moves
43.54 → 46.44 GB. The node remains Ready, pressure-free, untainted, and has 29 GiB free.

The run then refuses the pre-existing failed Lifecycle Authority release. Its old retained Pod has
Generation-110 rollout annotation `sha256:6645b9e5…`, Generation-111 registry image identity
`sha256:0f8017cc…`, and 18 CrashLoopBackOff restarts. Supported failed-release cleanup uninstalls it
and verifies absence. The command exits 1 after 25:32.173 before exact-image Authority recovery or
an AWS-admin worker; no active AWS-admin fence exists. The same-source exact-current clean-release
retry remains next and no new correction is licensed.
Generation 114 reproduces local/registry identities `sha256:34531fd4…`/`sha256:d5a18119…` from
cache, takes the exact-current containerd branch, and creates clean exact-image Lifecycle Authority
and Target Agent Pods; both are Ready with zero restarts. Protected recovery observes
`present/cleanup-proven/remint-used` at 03:11:25.960 EDT. The terminal diagnostic then refines to
`execution-failed/recovery-remint-ambiguous/target-delivery-failed/intent/unavailable/trust-install`.
The command exits 1 after 1:50.997, no AWS-admin Job or Pod remains, managed dangling inventory is
empty, node pressure is false, and host free space returns to 39 GiB. Stable counterexample
`AWS-ADMIN-CLEANUP-RECOVERY-TARGET-INTENT-TRUST-INSTALL-UNAVAILABLE-2026-08-30` licenses only
diagnosis of that exact trust-install boundary. Delivery, authentication, capability, retry,
cleanup, remint, permit, and journal behavior remain frozen. The active fence remains through
03:41:25 EDT; no supported successor starts before 03:41:26.
Source tracing proves signing succeeded and the authenticated Target trust-install client received
an unavailable response, while two production projections erased whether Target trust observation
or CAS failed. The locally qualified diagnostic carries only a closed cause covering generic
authenticated client failures, authored Target trust refusals, exact observation/CAS
unavailability, and client read-back; unknown private detail collapses to `other`. Focused
Sprint-2.116 passes **14/14**, primary **4731/4731**, auxiliary authority **27/33/31**, Fourmolu,
HLint, documentation/diff checks, and canonical `dev check` pass. Gate-built and installed binary
`sha256:d1aa5c8717a259421a580059df6fe6783c9efb36791cd1944cbabc6157b06412` is the
Generation-115 diagnostic input; no trust or delivery behavior changes.
Generation 115 starts after the fence and builds/publishes/imports exact identities
`sha256:3e290944…`, `sha256:e1afb61b…`, and `sha256:9d09895b…`; the build takes 1005.5 seconds and
the required import 140.8 seconds. It retains root session `root-session-3b9d5743…` and baseline
digest `a5756119…`, and brings exact-image Target Agent and Authority Pods Ready with zero restarts.
Recovery observes `present/cleanup-proven/remint-used` at 04:06:19.102 EDT. The exact terminal
refines to `intent/unavailable/trust-install/unavailable/observation`, and the command exits 1 after
1494.62 seconds. No worker remains; dangling managed inventory is empty; the node is Ready without
pressure or taint and has 42 GiB free. Register
`AWS-ADMIN-CLEANUP-RECOVERY-TARGET-TRUST-OBSERVATION-UNAVAILABLE-2026-08-30`: the Target failed
to authoritatively read its trust record before CAS, so only the closed Vault observation boundary
is licensed for diagnosis. The active fence remains through 04:36:19 EDT.
The locally qualified observation classifier retains the same cached-session/single-relogin
read while separating session acquisition/relogin, exact request 401/403, other HTTP/transport,
and invalid or identity-mismatched stored records. Exact request 404 alone remains missing; private
detail and stored values are erased. Focused **14/14**, primary **4731/4731**, auxiliary
**27/33/31**, lint/docs/diff, and canonical `dev check` pass; gate and installed binary are
byte-identical at `sha256:ffad42dae87c31e5e1ba5109bc54c17cc831ac81782fce40b7ab1864321c51c1`.
Generation 116 may deploy only after the active fence.
Generation 116 starts after the fence and builds/publishes/imports exact identities
`sha256:9531c714…`, `sha256:20f9ea40…`, and `sha256:6be037a9…`; the build takes 986.1 seconds and
the changed-image import 134.5 seconds. It retains root session `root-session-3b9d5743…` and
baseline digest `a5756119…`. Recovery observes `present/cleanup-proven/remint-used` at
05:00:49.674 EDT, and the exact terminal refines to
`intent/unavailable/trust-install/unavailable/observation/record/agent-identity-mismatch`.
Exact-image Target Agent and Authority Pods are Ready with zero restarts; no credential worker
remains, managed dangling inventory is empty, the node is Ready without pressure or taint, and 41
GiB is free. Register
`AWS-ADMIN-CLEANUP-RECOVERY-TARGET-TRUST-AGENT-IDENTITY-MISMATCH-2026-08-30`: the persisted trust
record binds the preceding rollout digest, while the endpoint-local and desired identities bind
the new exact rollout in the same cluster. Correct only same-cluster rollout adoption under the
existing exact-local-desired and monotonic Authority/CAS/read-back checks; cross-cluster identity
change still refuses. The active fence remains through 05:30:49 EDT.
That narrow correction is locally complete. A prior-rollout record is observable only for the
same exact target and endpoint-local cluster, while CAS still requires the desired record to equal
the endpoint's exact current Agent; all issuer, epoch, fence, version-CAS, and read-back checks
remain. Focused Sprint-2.116 passes **15/15**, broader Sprint-4.50 **595/595**, primary
**4732/4732**, auxiliary **27/33/31**, and all formatting/lint/docs/diff/canonical gates. The
gate-built and installed Generation-117 input is byte-identical at
`sha256:43322c9fd55677f0f87637f045356fa030cbe5c99f847ec7560987481882d1ca`; deploy it only
after the active fence.
Generation 117 starts after the fence and builds/publishes/imports exact identities
`sha256:22bae56e…`, `sha256:fe6d9ef6…`, and `sha256:5309514e…`; the build takes 988.0 seconds and
the required import 138.3 seconds. It retains root session `root-session-3b9d5743…` and baseline
digest `a5756119…`. Recovery observes `present/cleanup-proven/remint-used` at 05:55:11.802 EDT.
The terminal crosses trust observation/install and refines to
`target-delivery-failed/worker/agent-identity-unavailable`. Exact-image Target Agent and Authority
Pods are Ready with zero restarts; no credential or Target worker remains; managed dangling
inventory is empty; the node is Ready without pressure/taint and has 41 GiB free. Register
`AWS-ADMIN-CLEANUP-RECOVERY-TARGET-WORKER-AGENT-IDENTITY-UNAVAILABLE-2026-08-30` and diagnose only
the coordinator's exact Agent-identity observation before changing worker, trust, delivery, retry,
cleanup, remint, permit, journal, or receipt behavior. The active fence remains through 06:25:11
EDT.
Source and read-only cluster diagnosis then prove the exact Agent Deployment, rollout annotations,
UID, observed generation, and narrow RBAC grant are valid, while the one-shot credential Job has
no Kubernetes client token at the standard in-cluster path: automount is disabled and its sole
projected token is the distinct Vault-login audience/path. A locally qualified diagnostic now
nests `agent-identity-unavailable` into a closed value-free rollout-observation cause spanning
subprocess acquisition, missing kubeconfig, authorization, absence, other Kubernetes exit, and
exact response/identity/digest/UID/generation validation stages. Focused Sprint-2.116 is **15/15**,
the exact regression **1/1**, broader Sprint-4.50 **595/595**, primary **4732/4732**, and auxiliary
authority **27/33/31**; formatter/lint/docs/diff gates pass. The canonical gate exits 0, and its
built/installed Generation-118 input is byte-identical at
`sha256:2538b528a5c90b1b507aa9eea8a60ad164890e27520dd0a53805a8191c0d829e`. The fence has elapsed;
deploy and register the exact subclass before behavior changes.
Generation 118 starts at 06:32:09 EDT and builds/publishes/imports exact identities
`sha256:107716dd…`, `sha256:30ddcb04…`, and `sha256:751c0eab…`; build and import take 987.9 and
144.3 seconds. It retains root session `root-session-3b9d5743…` and baseline digest `a5756119…`.
Recovery observes `present/cleanup-proven/remint-used` at 06:56:44.677 EDT and live-refines the
terminal to `worker/agent-identity-unavailable/kubeconfig-unavailable`, proving the credential Job
lacks its Kubernetes client credential before Target-worker creation. Exact-image Agent and
Authority Pods are Ready with zero restarts; no credential or Target worker remains; managed
dangling image inventory is empty; node pressure/taints are absent and 41 GiB is free. Register
`AWS-ADMIN-CLEANUP-RECOVERY-TARGET-WORKER-KUBECONFIG-UNAVAILABLE-2026-08-30`; add only a distinct
Kubernetes API credential projection while preserving the Vault-login audience/path and every
existing identity, RBAC, rollout, trust, delivery, retry, cleanup, remint, permit, journal, and
receipt invariant. The active fence remains through 07:26:44 EDT.
The local correction keeps automount disabled and adds only to AWS-admin a separate
Kubernetes-API-audience token, projected root CA, and downward namespace at the standard client
path. Its retained substrate now consumes the existing `endpoints/kubernetes` owner for exact
post-DNAT API egress; the external-EAB worker receives neither projection nor API egress. Focused
Sprint-2.116 passes 17/17, the external one-shot lifecycle passes 14/14, and both chart schema
shapes render. Full primary and auxiliary suites pass 4733/4733 and 27/33/31; formatter, HLint,
documentation, diff, and canonical gates pass. The gate-built and installed Generation-119 input
is byte-identical at
`sha256:028ef5e112107e3631c30b2f210c9d3c974285e47e1c7e334548753aa000f3b1`. The fence
elapsed before qualification completed; the supported successor remains pending.
Generation 119 begins after the fence, builds/publishes/imports exact identities
`sha256:c550d7c6…`, `sha256:9e51495f…`, and `sha256:923436f6…` in 987.1 and 138.1 seconds,
and removes only the superseded Generation-118 local image. Root session `root-session-3b9d5743…`
and baseline digest `a5756119…` remain current. Recovery observes
`present/cleanup-proven/remint-used` at 07:59:03.579 EDT and the exact Pod-log terminal advances to
`worker-terminal-line=session-revocation-failed`; public receipt-decode behavior is unchanged.
Register `AWS-ADMIN-CLEANUP-RECOVERY-WORKER-SESSION-REVOCATION-FAILED-2026-08-30` and diagnose
only that closed revocation boundary. Live NetworkPolicy evidence is exact at
`192.168.2.46/32:6443`; current Agent and Authority Pods are exact-image Ready with zero restarts,
no one-shot worker remains, and host/node residue checks are clean. The active fence remains
through 08:29:03 EDT.
Source tracing then proves the AWS-admin worker collapsed a closed typed service-session lifecycle
result into that single token. The locally qualified value-free terminal grammar now separates
auditor login/role cleanup and fenced journal, binding, pre-clean, cleaned-login-ambiguity,
cleanup, cleanup-exception, and cleanup-journal stages; audit stages retain only closed
identity/observation/classification/visibility/stable-zero causes. Tokens, accessors, Vault text,
journal coordinates, operation identifiers, and target/receipt values remain unrenderable, direct
revoke status remains provisional, and no lifecycle behavior changes. Focused Sprint-2.116 remains
17/17, full primary passes 4733/4733, auxiliary suites pass 27/33/31, and formatter, HLint,
documentation, and diff gates pass. Canonical qualification and Generation-120 live classification
also passes; its gate-built and installed Generation-120 input is byte-identical at
`sha256:0f2b97eddf225f27db9ac01ddfdc601b509cc71e08f0412c181d4f01df4cbd9b`. Live
classification remains pending.
Generation 120 starts after the fence and builds/publishes/imports exact identities
`sha256:4febc4ff…`, `sha256:bd4cb86b…`, and `sha256:a0c22958…` in 987.4 and 146.7
seconds. It retains root session `root-session-3b9d5743…` and baseline digest `a5756119…`.
Recovery observes `present/cleanup-proven/remint-used` at 08:54:13.791 EDT and live-refines the
terminal to `session-revocation-failed/journal-unavailable`; public receipt-decode behavior is
unchanged. Register
`AWS-ADMIN-CLEANUP-RECOVERY-WORKER-SESSION-JOURNAL-UNAVAILABLE-2026-08-30` and distinguish
only binding allocation, pre-action acquisition, or post-action finalization before changing the
auditor's two-minute lease or journal behavior. Exact-image Agent and Authority Pods are Ready,
one-shot residue is absent, NetworkPolicy generation 42 retains `192.168.2.46/32:6443`, and
host/node checks are clean with 44 GiB free. The active fence remains through 09:24:13 EDT.
The local stage diagnostic now gives binding allocation its own token and uses a closed action-entry
latch to separate pre-action acquisition from post-entry finalization. The latch is value-free and
behavior-neutral. Focused Sprint-2.116 passes 18/18; full qualification and Generation 121 remain
pending behind the active fence. Full primary and auxiliary suites pass 4734/4734 and 27/33/31;
formatter, HLint, documentation, and diff gates pass, with canonical and byte-identity checks still
pending. Canonical `prodbox dev check` then exits 0; its gate-built and installed Generation-121
input is byte-identical at
`sha256:084f01e867631b96152a3343fc36a2e9f2a81fb3d6ee4536695c1f4c2e4e97eb` and remains
fenced until 09:24:14 EDT.
Read-only events then settle the stage without a diagnostic-only successor: the credential worker
starts at 08:54:15, creates the Target worker at 08:54:29, and stops at 08:57:02, after its
120-second auditor expired. The local correction gives that accessor-free batch auditor one
compiled 300-second bound shared by role reconciliation and worker validation, strictly containing
the 180-second child runtime plus finalization margin. The prior byte identity is superseded and
focused 19/19, full primary 4735/4735, auxiliary 27/33/31, formatter, HLint, documentation, and
diff gates pass; canonical qualification also exits 0 and its gate-built/installed input is
byte-identical at
`sha256:407a14ea70b3d17d9bb86db6357cb3ac2f91e99c894ed2827b4cbafc498fdc06`. The same
events register the distinct, not-yet-admitted
`TARGET-WORKER-RUN-AS-NON-ROOT-IMAGE-METADATA-2026-08-30` counterexample.
Generation 121 then deploys the locally qualified 300-second source correction after the fence.
It builds/publishes/imports exact identities `sha256:6fd0d5c4…`, `sha256:e4745140…`, and
`sha256:632b9653…` in 1006.4 and 131.8 seconds, deleting only Generation 120's superseded local
image. Recovery observes `present/cleanup-proven/remint-used` at 10:00:58.906 EDT, but the exact
terminal remains `session-revocation-failed/finalization/journal-unavailable` and public receipt
decode refuses. Timestamped events prove action entry at 10:01:13, repeated Target-worker
`runAsNonRoot` image-metadata refusal through 10:03:43, and worker service-token revocation at
10:03:48. The source maximum therefore is not live completion evidence; Sprint 2.116 remains
Active to identify and correct the auditor's post-action journal loss before the separately ordered
Target-worker runtime-identity correction. Postflight retains exact `192.168.2.46/32:6443` API
egress at NetworkPolicy generation 43, no one-shot residue, exact-image Ready retained Pods, empty
managed dangling inventory, a pressure/taint-free Ready node, and 44 GiB free. The recovery fence
runs through 10:30:58 EDT; no successor is admitted before 10:30:59.
The next local diagnostic closes the remaining observation gap without carrying journal detail.
An issued auditor lease must now equal the compiled 300-second role bound; a shorter otherwise
valid batch lease refuses before action entry as `auditor-lease-insufficient`. Journal
unavailability retains only authentication rejection, authorization rejection, absence, timeout,
transport, decode, invalid state, or other below the already closed acquisition/finalization
stage. Focused Sprint-2.116 passes 20/20, exact AWS-admin Authority 42/42, primary 4736/4736, and
auxiliary 27/33/31; warning-clean compilation and Fourmolu pass, with the remaining local gates
then passing as well. HLint reports `No hints`; documentation, diff, and canonical gates pass, and
the gate-built/installed executable is byte-identical at `sha256:1ab85cd4…`. The fence elapsed at
10:30:59 EDT and Generation 122 is admitted.
Generation 122 builds/publishes/imports `sha256:32508d57…`, `sha256:6aa2ce14…`, and
`sha256:9c4328df…` in 1003.2 and 121.5 seconds, deleting only Generation 121's local image. The
baseline again returns root session `root-session-3b9d5743…` and digest `a5756119…`; recovery at
10:58:13.372 EDT refuses before action as `auditor-lease-insufficient`, positively proving Vault
still issued less than the compiled bound. Register
`VAULT-BASELINE-TARGET-REVISION-OMITTED-2026-08-30`: the role change did not append a compiled
baseline target, so the completed retained root/provisioner session remained current and replayed
its old read-back. Sprint 2.116 now appends that exact lease-containment target, preserving the
native fresh-root-session/current-target recovery path and leaving the retained journal intact.
Postflight is clean at NetworkPolicy generation 44 with no one-shot residue, exact-image Ready
retained Pods, empty managed dangling inventory, a pressure/taint-free Ready node, and 43 GiB free.
The fence runs through 11:28:13 EDT; no successor is admitted before 11:28:14.
The local correction appends
`BaselineCredentialProvisionerAuditorLeaseContainment` after the exact Generation-122 target set.
The old 19-target receipt remains decodable only as a closed restart input, is never current or
valid in-progress state, and makes the native planner mint a fresh root-session identity before
reapplying and reading back all 20 targets. A test-local historical wire schema pins that behavior
without deleting or rewriting the retained receipt; the older 18-target schema remains separately
pinned. Focused Sprint-2.116 passes 21/21, primary 4737/4737, and auxiliary authority suites
27/33/31; warning-clean compilation, Fourmolu, HLint, documentation, repository-policy, diff, and
canonical gates pass. The gate-built and installed executable is byte-identical at
`sha256:9ddf4c88…`; the live fence remains unchanged.
Generation 123 starts after explicit 11:28:21 EDT admission and
builds/publishes/imports `sha256:1788eda1…`, `sha256:9336a8f9…`, and `sha256:ae2689ff…` in
990.3 and 149.3 seconds, deleting only Generation 122's local image. The new baseline target forces
fresh root session `root-session-9c54db6a…` and exact digest `a5756119…`. The issued auditor crosses
exact lease admission and session finalization; the terminal advances to
`execution-failed/recovery-remint-ambiguous/target-delivery-failed/worker/observation-failed`.
Read-only events confirm the registered Target-runtime counterexample: the Job is created at
11:53:39 EDT and kubelet repeatedly refuses its root-metadata image through 11:55:59. Cleanup leaves
no one-shot Job/Pod; NetworkPolicy generation 45, exact-image Ready retained workloads, a
pressure/taint-free Ready node, and 43 GiB free remain clean. Sprint 2.116 now admits the explicit
Target-worker UID/GID/filesystem-group correction. Its conservative fence runs through 12:26:26
EDT; no successor is admitted before 12:26:27.
The local renderer correction assigns Target-worker UID, GID, and filesystem group `65532` plus
`OnRootMismatch` at the Pod boundary. The role-neutral union image remains unchanged; every prior
hardening, projected identity, immutable-image/Pod attestation, and cleanup invariant remains in
force. A structural regression compares the complete security-context object. The Target
materializer passes 34/34, focused Sprint-2.116 22/22, primary 4737/4737, and auxiliary authority
suites 27/33/31; warning-clean compilation, Fourmolu, HLint, documentation, repository-policy,
diff, and canonical gates pass. The gate-built and installed executable is byte-identical at
`sha256:7bd27096…`; the live fence remains unchanged.
Generation 125 starts after explicit 13:25:01 EDT admission and builds/publishes/imports
`sha256:105f2e58…`, `sha256:7a3d0182…`, and `sha256:2987e948…` in 987.1 and 142.2 seconds,
deleting only Generation 124's local image. Retained root session `root-session-9c54db6a…` and
digest `a5756119…` remain exact. The Target worker starts at 13:50:01 and is cleaned at 13:52:31;
the credential worker is cleaned at 13:52:36. The protected terminal names exact
`worker/observation-failed/runtime-image-identity-invalid`. Register
`TARGET-WORKER-REPOSITORY-QUALIFIED-RUNTIME-IDENTITY-2026-08-30`: reuse the credential worker's
canonical repository-qualified runtime-manifest parser for Target observation and delete the
narrow duplicate without relaxing digest equality or changing downstream behavior. Postflight is
clean at NetworkPolicy generation 47, no one-shot residue, exact-image Ready Agent generation 70
and Authority generation 12, a pressure/taint-free Ready node, and 43 GiB free. The conservative
fence runs through 14:22:57 EDT; no Generation 126 command is admitted before 14:22:58.
The local correction deletes the narrower Target-only parser and reuses the credential worker's
canonical runtime-manifest interpretation without relaxing digest equality. The warning-clean
all-target build, Target-materializer 34/34, focused Sprint-2.116 22/22, exact AWS-admin Authority
42/42, full primary 4737/4737, and auxiliary 27/33/31 pass. Fourmolu, HLint, and diff gates pass;
documentation, repository-policy, and canonical gates also pass. `prodbox dev check` exits 0; its
gate-built and installed executable is byte-identical at `sha256:fd1760ea…`.
Generation 126 starts after explicit 14:23:05 EDT admission and builds/publishes/imports
`sha256:0ae58422…`, `sha256:63e529a2…`, and `sha256:74a390fb…` in 989.2 and 128.0 seconds,
deleting only Generation 125's local image. The credential worker starts at 14:47:14 and the
Target worker is created/started at 14:47:25/14:47:26; cleanup removes them at 14:47:31 and
14:47:34. The exact worker diagnostic has one unique canonical envelope line, and execution
advances through Target delivery, live-proving and closing Sprint 2.116. The later distinct
Authority Backup genesis-copy terminal is
`AuthorityBackupExportResponseInvalid ControlPlaneRequestInvalid`. Sprint 2.117 is Active and
registers `AUTHORITY-BACKUP-EXPORT-200-RESPONSE-INVALID-2026-08-30` for a closed value-free
response-shape diagnostic before behavior changes. Postflight retains exact root identity,
NetworkPolicy generation 48, exact-image Ready Agent generation 71 and Authority generation 13,
no one-shot residue, a pressure/taint-free Ready node, and 42 GiB free. Its conservative fence runs
through 15:17:55 EDT; no Generation 127 command is admitted before 15:17:56.
The Sprint-2.117 diagnostic now classifies only direct response, endpoint success, endpoint
failure, empty, or other while leaving the mismatch fail-closed. Its private-value collapse and
unique-token table passes in the complete Authority Backup group at 18/18; primary passes
4738/4738 and auxiliary suites 27/33/31. Repository policy, Fourmolu, HLint, warning-clean build,
documentation, diff, and canonical gates pass. The gate-built and installed executable is
byte-identical at `sha256:f6b8abba…`; Generation 127 remains queued behind the active fence.
Generation 127 starts after explicit 15:18:02 EDT admission and builds/publishes/imports
`sha256:7ea3130e…`, `sha256:7bccc219…`, and `sha256:37e0e3ee…` in 991.1 and 135.5
seconds, deleting only Generation 126's local image. Exact-image Agent generation 72 and Authority
generation 14 start at 15:41:55/15:42:26. Retained admission creates no new one-shot and reports
exact `AuthorityBackupExportResponseEndpointSuccess`, licensing only direct canonical HTTP-200
success encoding. The local correction does exactly that while retaining closed non-200 summaries
and every client, authentication, replay, digest, copy, and admission rule. Postflight has no
one-shot residue, NetworkPolicy generation 49, a pressure/taint-free Ready node, and 38 GiB free;
the run creates no successor worker fence.
The direct-success correction is locally complete: Authority Backup passes 18/18, primary
4738/4738, and auxiliary suites 27/33/31; repository policy, Fourmolu, HLint, warning-clean build,
documentation, diff, and canonical gates pass. The gate-built and installed executable is
byte-identical at `sha256:753f18a4…`; Generation 128 is admitted without a worker fence.
Generation 128 starts after explicit 15:58:31 EDT admission and builds/publishes/imports
`sha256:54c4fddd…`, `sha256:04245737…`, and `sha256:89653645…` in 1001.8 and 147.0
seconds, deleting only Generation 127's superseded local image and untagged registry manifest.
Exact-image Agent generation 73 and Authority generation 15 start at 16:23:40/16:24:07.
Authority Backup export/copy succeeds, live-proving Sprint 2.117. Retained first-reconcile
continuation creates its credential worker at 16:24:28; the container starts at 16:24:29 and is
killed at 16:24:36. Its exact closed terminal names
`aws/create-lifecycle-role/service/other-client`, registering
`AWS-ADMIN-CREATE-LIFECYCLE-ROLE-OTHER-CLIENT-2026-08-30` under active Sprint 2.118 for a
behavior-neutral documented-fault refinement. Postflight has no one-shot residue, NetworkPolicy
generation 50, exact-image Ready retained workloads, a pressure/taint-free Ready node, and 38 GiB
free. The conservative fence runs through 16:54:56 EDT; no Generation 129 command is admitted
before 16:54:57.
The behavior-neutral Sprint-2.118 diagnostic adds the four documented `CreateRole` client-side
faults missing from the closed service classifier and retains every existing fallback and behavior.
Focused and exhaustive cases pass 1/1 each, primary 4739/4739, and auxiliary 27/33/31; repository
policy, Fourmolu, HLint, warning-clean build, documentation, diff, and canonical gates pass. The
gate-built and installed executable is byte-identical at `sha256:e3f64647…`; Generation 129 remains
queued behind the active worker fence.
Generation 129 starts after explicit 16:55:06 EDT admission and builds/publishes/imports
`sha256:7fa9bcc2…`, `sha256:a76d401a…`, and `sha256:c5a8fe6f…` in 994.1 and 148.5
seconds, deleting only Generation 128's superseded local image and untagged registry manifest.
Exact-image Agent generation 74 and Authority generation 16 start at 17:19:38/17:20:06. The
earlier `create-lifecycle-role/service/other-client` condition does not recur, closing Sprint
2.118; the later terminal names `iam-prerequisite-failed/role-read-back-mismatch`. Register
`AWS-ADMIN-LIFECYCLE-ROLE-READ-BACK-MISMATCH-2026-08-30` under active Sprint 2.119 before
behavior changes. The credential worker starts at 17:20:27 and is killed at 17:20:33. Postflight
has no one-shot residue, NetworkPolicy generation 51, exact-image Ready retained workloads, a
pressure/taint-free Ready node, and 42 GiB free. The conservative fence runs through 17:50:53 EDT;
no Generation 130 command is admitted before 17:50:54.
The behavior-neutral Sprint-2.119 diagnostic replaces private role read-back text with four
value-free causes and retains the exact reconciliation/comparison behavior. Focused cases pass
1/1, primary 4740/4740, and auxiliary 27/33/31; repository policy, Fourmolu, HLint, warning-clean
build, documentation, diff, and canonical gates pass. The gate-built and installed executable is
byte-identical at `sha256:beb4342f…`; Generation 130 remains queued behind the active worker fence.
Generation 130 starts after explicit 17:51:02 EDT admission and builds/publishes/imports
`sha256:dd5128d6…`, `sha256:6b81ecf2…`, and `sha256:d135c437…` in 989.1 and 141.7
seconds, deleting only Generation 129's superseded local image and untagged registry manifest.
Exact-image Agent generation 75 and Authority generation 17 start at 18:15:09/18:15:36. The
credential worker starts at 18:15:57 and is killed at 18:16:03; its exact terminal names
`role-read-back-mismatch/trust-policy-mismatch`, closing Sprint 2.119. Register
`AWS-ADMIN-LIFECYCLE-ROLE-TRUST-POLICY-SHAPE-2026-08-30` under active Sprint 2.120 for a
behavior-neutral invalid/singleton-equivalent/other policy-shape classifier. Postflight has no
one-shot residue, NetworkPolicy generation 52, exact-image Ready retained workloads, a
pressure/taint-free Ready node, and 42 GiB free. The conservative fence runs through 18:46:23 EDT;
no Generation 131 command is admitted before 18:46:24.
The behavior-neutral Sprint-2.120 diagnostic classifies invalid, IAM-singleton-equivalent, or other
trust-policy shapes while leaving acceptance exact. Focused cases pass 1/1, primary 4741/4741, and
auxiliary 27/33/31; repository policy, Fourmolu, HLint, warning-clean build, documentation, diff,
and canonical gates pass. The gate-built and installed executable is byte-identical at
`sha256:5f88e335…`; Generation 131 remains queued behind the active worker fence.
Generation 131 starts after explicit 18:46:33 EDT admission and builds/publishes/imports
`sha256:216a433b…`, `sha256:88ff9d5a…`, and `sha256:e61860c9…` in 986.5 and 140.7
seconds, deleting only Generation 130's superseded local image and untagged registry manifest.
Exact-image Agent generation 76 and Authority generation 18 start at 19:10:44/19:11:11. The
credential worker starts at 19:11:32 and is killed at 19:11:38; its exact terminal names
`trust-policy-mismatch/iam-singleton-equivalent`, closing Sprint 2.120 and licensing only the
documented singleton equality correction under active Sprint 2.121. Postflight has no one-shot
residue, NetworkPolicy generation 53, exact-image Ready retained workloads, a pressure/taint-free
Ready node, and 42 GiB free. The conservative fence runs through 19:41:58 EDT; no Generation 132
command is admitted before 19:41:59.
The Sprint-2.121 correction admits exact trust-policy equality or equality after only those three
live-proven singleton forms; permissions-policy equality remains exact. Positive and semantic
counterexample cases pass through both the pure predicate and injected native IAM seam. Focused
cases pass 2/2, primary 4743/4743, and auxiliary 27/33/31; repository policy, Fourmolu, HLint,
warning-clean build, documentation, diff, and canonical gates pass. The gate-built and installed
executable is byte-identical at `sha256:008e2e6f…`; Generation 132 remains queued behind the active
worker fence.
Generation 132 starts after explicit 19:42:04 EDT admission and builds/publishes/imports
`sha256:6aa223b3…`, `sha256:2cb0d1c3…`, and `sha256:d73d4bff…` in 985.2 and 151.4
seconds, deleting only Generation 131's superseded local image and untagged registry manifest.
Exact-image Agent generation 77 and Authority generation 19 start at 20:06:13/20:06:39. A Target
worker starts at 20:07:09; the owning credential worker is killed at 20:07:17. The successor
credential worker starts at 20:07:21 and is killed at 20:07:30 with exact terminal
`target-observation-unobservable/client/response-codec/invalid`. This crosses and closes Sprint
2.121. Register `TARGET-MATERIAL-RESPONSE-CODEC-INVALID-2026-08-30` under active Sprint 2.122 for
a behavior-neutral classifier of the HTTP status accompanying the invalid response body.
Postflight has no one-shot residue, NetworkPolicy generation 54, exact-image Ready retained
workloads, a pressure/taint-free Ready node, and 42 GiB free. The conservative fence runs through
20:37:50 EDT; no Generation 133 command is admitted before 20:37:51.
The behavior-neutral Sprint-2.122 diagnostic refines only a codec-invalid Target-material response
with its closed HTTP status class; response bytes and numeric status remain unrepresentable, and
all behavior is unchanged. Focused and pre-existing exhaustive cases pass 1/1 each, primary
4744/4744, and auxiliary 27/33/31; repository policy, Fourmolu, HLint, warning-clean build,
documentation, diff, and canonical gates pass. The gate-built and installed executable is
byte-identical at `sha256:679f2ef8…`. Generation 133 starts after explicit 20:37:59 EDT admission
and deploys local/registry/OCI identities `sha256:255d7693…`, `sha256:ca4aac58…`, and
`sha256:c0ef0c55…`, deleting only Generation 132's superseded local image and untagged registry
manifest. Exact-image Agent generation 78 and Authority generation 20 start at 21:02:10/21:02:37.
A first credential worker starts at 21:02:56 and creates a Target worker that starts at 21:03:08;
a later credential worker starts at 21:03:21 and is killed at 21:03:23 with exact terminal
`AwsAdminCoordinatorAttestFailed (AwsAdminProvisionerClientRefused "pod-heartbeat-stale")`.
Source closure shows the Job boundary captures one command-start heartbeat and reuses it across
later retained first-reconcile members. Register
`AWS-ADMIN-SUCCESSOR-JOB-HEARTBEAT-STALE-2026-08-30` under active Sprint `2.123`; sample a fresh
heartbeat for each Job attempt but retain that exact value across the attempt. Postflight has no
one-shot residue, exact-image Ready retained workloads, a pressure/taint-free Ready node, and 41
GiB free. The conservative fence runs through 21:33:43 EDT; no Generation 134 command is admitted
before 21:33:44.
The Sprint-2.123 correction samples one fallible heartbeat per Job attempt and carries it unchanged
through render, observation, attestation, and pre-delete observation; completed recovery uses the
signed binding's value and clock failure creates no Job. The frozen two-attempt mapping `[h0, h0]`
becomes `[h0, h1]` without changing the 30-second bound, absolute deadlines, topology, resources,
permits, or cleanup. Focused cases pass 3/3, the AWS-admin Authority group 50/50, primary
4747/4747, and auxiliaries 27/33/31; repository policy, Fourmolu, HLint, warning-clean build,
documentation, diff, and canonical gates pass. The built/installed executable is byte-identical at
`sha256:bfbc6201…`; Generation 134 is admitted after the expired fence.
Generation 134 starts after a clean 21:35:09 EDT preflight and explicit 21:35:31 start, then
builds/publishes/imports `sha256:58d18632…`, `sha256:d2e1ca8d…`, and `sha256:01dddf35…` in
993.8 and 144.2 seconds while deleting only Generation 133's superseded local image and untagged
registry manifest. Exact-image Agent generation 79 and Authority generation 21 start at
21:59:38/22:00:04. Credential workers start at 22:00:23 and 22:00:45; the fresh-heartbeat
successor crosses the former attestation refusal and is cleaned at 22:00:55. A Target worker runs
from 22:00:32 through 22:00:39. The exact later terminal is
`target-observation-unobservable/client/response-codec/invalid/status/server`, live-proving
Sprints 2.122 and 2.123. Register
`TARGET-MATERIAL-CODEC-INVALID-SERVER-SHAPE-2026-08-30` under active Sprint 2.124 for a
behavior-neutral exact authenticated-role plaintext response classifier before response behavior
changes. Postflight has no one-shot residue, exact-image Ready retained workloads, a
pressure/taint-free Ready node, and 41 GiB free. The conservative fence runs through 22:31:15 EDT;
no Generation 135 command is admitted before 22:31:16.
The Sprint-2.124 classifier is locally complete. The authenticated-role interpreter's total
projection owns all 21 static status/body pairs; the Target-material server decode boundary emits
only the matching closed observation or `other`, and retains neither body nor numeric status.
Exact-pair, wrong-status, prefix/suffix, private-collapse, and production-seam cases pass. Focused
cases are **2/2**, the AWS-admin Authority group **51/51**, primary **4748/4748**, and auxiliaries
**27/33/31**. Repository policy, Fourmolu, HLint (`No hints`), warning-clean all-target compilation,
documentation, diff, and canonical gates pass. The gate-built and installed executable is
byte-identical at `sha256:28c6928d165c2fdfb66f1b9e165d60cf30b1be4ab8be194bc516d0f90b915006`;
Generation 135 is admitted after the expired fence.
Generation 135 starts at 22:31:26 EDT and builds/publishes/imports
`sha256:2e6c9f0f…`, `sha256:a8eb3e55…`, and `sha256:cb8e07e4…` in 994.6/153.8 seconds,
removing exactly Generation 134's superseded registry manifest and local image. Exact-image Agent
and Authority containers start at 22:55:59/22:56:25; credential and Target workers start at
22:56:45/22:56:56 and are killed at 22:57:06/22:57:03. The outer command-output observer truncates
the Docker-heavy stream before retaining the protected terminal, so the run is not Sprint-2.124
completion evidence and no later cause is inferred. Postflight at 22:59:02 proves zero one-shot
Jobs, exact-image Ready retained workloads, a Ready pressure/taint-free node, and 41 GiB free. The
conservative fence runs through 23:27:26 EDT; no Generation 136 command is admitted before
23:27:27. Repeat the same supported reconcile with a bounded filtered observer.
Generation 136 starts at 23:28:19 EDT, reuses the unchanged exact image/manifest, exits 1 before
any one-shot Job, and creates no fence; its first bounded filter does not retain the pre-worker
line. Generation 137 starts at 23:30:45 with the observer widened and retains exact terminal
`Authority backup admission reconciliation failed: AuthorityBackupHealthObservationFailed
"AuthorityAggregateBackupResponseInvalid ControlPlaneRequestInvalid"`, exit 1, again before any
one-shot Job. Sprint 2.124 is Done on its code-owned surface with deployment proof pending.
Register `AUTHORITY-AGGREGATE-BACKUP-RESPONSE-CODEC-INVALID-2026-08-30` under active Sprint 2.125
for an exact behavior-neutral aggregate-backup response-shape diagnostic.
The Sprint-2.125 diagnostic is locally complete: only the aggregate-backup codec-invalid branch
retains the interpreter-owned exact-pair/`other` observation, while checkpoint backup and all
runtime decisions remain unchanged. Focused Sprint-2.125 is **1/1**, the Authority Backup group
**19/19**, primary **4749/4749**, and auxiliaries **27/33/31**; Fourmolu, HLint (`No hints`),
warning-clean all-target compilation, documentation, diff, and canonical gates pass. The installed
gate binary is exact at
`sha256:1724e92e4d2d9109bbb73d6450e9bb63a2572cad21733e068dc9967c3cb885bc`; Generation 138 is
the remaining live proof.
Generation 138 starts at 23:57:22 EDT on August 30, builds/publishes/imports
`sha256:2486c0f5…`, `sha256:05f7561d…`, and `sha256:f6609c76…`, and removes only Generation
135's superseded registry manifest and local image. It exits at 00:23:10 EDT on August 31 with the
earlier rollout-transition terminal `Lifecycle Authority config is unobservable: ... HttpTimeout
"connection timeout"` and therefore supplies no Sprint-2.125 evidence. Postflight proves zero
one-shot Jobs and no fence; Target Agent generation 81, Lifecycle Authority generation 23, and
Authority Backup generation 63 are Ready on the exact new image, with a pressure/taint-free Ready
node and 36 GiB free. Run unchanged Generation 139 against the settled revision.
Generation 139 starts at 00:25:39 EDT, reuses exact local image `sha256:2486c0f5…` and registry
manifest `sha256:05f7561d…`, and exits at 00:27:02 with exact earlier terminal `Lifecycle Authority
in-force config is unobservable: ConfigBackupResponseInvalid ControlPlaneRequestInvalid`. Sprint
2.125 is Done on its code-owned surface with live proof pending. Register
`LIFECYCLE-AUTHORITY-IN-FORCE-CONFIG-RESPONSE-CODEC-INVALID-2026-08-31` under active Sprint 2.126
for a behavior-neutral exact response-shape diagnostic before config backup, in-force projection,
retry, reconciliation, or response behavior changes. Postflight proves zero one-shot Jobs and no
fence, exact-image zero-restart Ready retained workloads, a pressure/taint-free Ready node, and 36
GiB free.
The Sprint-2.126 diagnostic is locally complete: only the config-backup codec-invalid branch
retains the interpreter-owned exact-pair/`other` observation, while copy/observe decisions,
in-force projection, reconciliation, and checkpoint backup remain unchanged. Focused Sprint-2.126
is **1/1**, the in-force-config endpoint group **11/11**, primary **4750/4750**, and auxiliaries
**27/33/31**; Fourmolu, HLint (`No hints`), warning-clean all-target compilation, documentation,
diff, and canonical gates pass. The installed gate binary is exact at
`sha256:968b92038bba64be3bd9d784f30d253dac489a5ba4c05b68cafac1ba5cb5a8cb`; Generation 140 is
the remaining live proof.
Generation 140 starts at 00:44:25 EDT, builds/publishes/imports `sha256:1ebf04ac…`,
`sha256:f3df35ba…`, and `sha256:a8274de5…`, and removes only Generation 138/139's superseded
registry manifest and local image. It exits at 01:07:37 with the earlier rollout-transition terminal
`Lifecycle Authority config is unobservable: ... HttpTimeout "connection timeout"` and therefore
supplies no Sprint-2.126 evidence. Postflight proves zero one-shot Jobs and no fence; Target Agent
generation 82, Lifecycle Authority generation 24, and Authority Backup generation 64 are
zero-restart Ready on the exact new image, with a pressure/taint-free Ready node and 36 GiB free.
Run unchanged Generation 141 against the settled revision.
Generation 141 starts at 01:09:06 EDT, reuses exact local image `sha256:1ebf04ac…` and registry
manifest `sha256:f3df35ba…`, and exits at 01:10:29 with exact
`ConfigBackupResponseInvalid ControlPlaneRequestInvalid
(AuthenticatedRolePlainResponseKnown AuthenticatedRoleReplayCapacityExhausted)`, live-proving
Sprint 2.126. Register `LIFECYCLE-REPLAY-IMMEDIATE-RETRY-WINDOW-2026-08-31` under active Sprint
2.127. The first diagnosis targets two retained Lifecycle Authority `56 + 4` request envelopes: one
hard first-reconcile plus config observe/propose, retained-root-marker observation, and load attempt
and one immediate retry inside the prior deadline-plus-skew horizon. Generation 145 later proves
that this is necessary but not sufficient because the nested refusal is emitted by the Authority
Backup Adapter's independent replay projection. Postflight proves zero one-shot Jobs and no fence, exact-image zero-restart Ready retained
workloads, a pressure/taint-free Ready node, and 36 GiB free.
The initial Sprint-2.127 correction derives 59 requests per attempt and capacity 118. Its pure trace
passes, and canonical non-empty v2/v3 state widens into v4 without loss. The retained-replay suite is **32/32**, focused primary assertion
**1/1**, primary **4750/4750**, and auxiliaries **27/33/32**; Fourmolu, HLint (`No hints`),
warning-clean all-target compilation, documentation, diff, and canonical gates pass. The installed
gate binary is exact at
`sha256:9ef3f378928fe9c28dc684dc22b97fc866e6ed820b31582b5fa5eb113432ba23`, but live proof
falsifies its count. Generation 142 builds/publishes/imports `sha256:331dbc9d…`,
`sha256:c5a4b0fb…`, and `sha256:3e153121…`, then exits on the known rollout config timeout with
zero Jobs/fence and exact-image Ready retained workloads. Generation 143 starts 42 seconds later
and again reports exact replay-capacity exhaustion. The omitted authenticated
retained-root-marker observation makes a complete attempt 60 requests and the two-attempt capacity
120; widen the already-live v4/118 projection into v5 without entry loss.
The second, Lifecycle-Authority-only Sprint-2.127 revision passes locally: the pure trace retains all 120 requests and
reproduces capacity-64 refusal at retry request five, while canonical non-empty v2/v3/v4 state
widens into v5 without loss. The retained-replay suite is **32/32**, focused primary assertion
**1/1**, primary **4750/4750**, and auxiliaries **27/33/32**; Fourmolu, HLint (`No hints`),
warning-clean all-target compilation, documentation, diff, and canonical gates pass. The corrected
installed binary is exact at
`sha256:1076bab06d59979d4483dde1e6b3ab44d0c1f0f65673cedf1ef5ed27d79d6aec`. Generation 144
builds/publishes/imports `sha256:a78b97c3…`, `sha256:3542ca14…`, and `sha256:81f1438a…`, rolls
Target Agent generation 84, Lifecycle Authority generation 26, and Authority Backup generation 66
onto the exact image, and exits on the known rollout config timeout. The shell resumes only after
the immediate-retry horizon, so that interval supplies no retry proof. Generation 145 starts at
09:15:00 against the settled revision and still reports exact replay-capacity exhaustion at
09:16:27. With every earlier entry expired, source closure proves one settled attempt itself sends
five requests to the Adapter: backup health plus four config-backup observations; generic capacity
four refuses the final load. Register
`AUTHORITY-BACKUP-REPLAY-SINGLE-COMPLETE-RECONCILE-2026-08-31` within Sprint 2.127.
The current correction retains Authority capacity 120, gives only the Adapter capacity
`2 * (3 repair + 6 config) = 18`, leaves siblings at four, and advances the canonical codec to v6
with widening-only v2/v3/v4/v5 migration. The focused replay suite passes **33/33**, primary
**4750/4750**, and auxiliaries **27/33/33**; documentation/diff, formatting/lint, warning-clean
all-target compilation, and canonical gates pass. Both integration entrypoints reproduce the same
eight later Phase-5 fake-tool failures at **55/63**, before reaching their intended assertions; they
do not exercise the replay change. The installed binary is exact at `sha256:b3e8a965…`; live
rollout/immediate-retry validation remains.
Generation 146 builds/publishes exact runtime identities `sha256:37941ace…` and
`sha256:6a05e859…`, rolls Target Agent, Lifecycle Authority, and Authority Backup to generations
85, 27, and 67, and exits on the expected rollout config timeout. Generation 147 starts unchanged
34 seconds later, reuses the exact identities, observes the current Authority config and retained-
root marker, and crosses both replay refusals without clearing retained entries. It then reaches
the distinct Provider dispatch and reports exact absent DNS for
`provider-worker.provider-worker.svc.cluster.local`; postflight confirms the namespace itself is
absent. Sprint `2.127` is Done. Register
`PROVIDER-WORKER-DNS-ABSENT-BEFORE-FIRST-PROVIDER-DISPATCH-2026-08-31` under Sprint `2.128` and
trace declared install/admission order before behavior changes.
Source closure proves `ComponentGatewayDaemonFull` and `ComponentChartProviderWorker` were sibling
Authority-Backup dependents, while the Gateway component group's namespace guardrail performs the
first Provider readiness dispatch. Stable constructor order therefore placed that dispatch before
worker installation. Add the missing Gateway-full dependency on Provider Worker. The focused order
proof passes **1/1**, and the rebuilt dry-run now places worker readiness before both Gateway chart
reconciliation and the guardrail. The canonical generated Tier-0 witness is current; primary
**4750/4750**, auxiliaries **27/33/33**, formatting/lint, warning-clean all-target compilation,
documentation/diff, and canonical gates pass. The installed binary is exact at
`sha256:094803cd…`; live validation remains.
Generations 148/149 deploy exact runtime identities `sha256:aad6464d…` and
`sha256:f3977701…`; the immediate retry advances/read-backs the new in-force config and creates
Provider Worker generation 1 before Gateway. Postflight proves its Service, ready endpoint, and
zero-restart exact-image Pod, so the prior DNS-absence boundary is crossed and Sprint `2.128` is
Done. The first ready Provider dispatch then reports exact connection timeout. Register
`PROVIDER-WORKER-FIRST-READY-DISPATCH-TIMEOUT-2026-08-31` under Sprint `2.129` and add only a closed
payload-free stage/cause diagnostic before behavior changes. Source closure distinguishes the
client's exact connection timeout from response timeout and adds one eleven-stage/three-cause trace
from owned-route socket ingress through authenticated admission, narrow-session acquisition,
Provider execution, response encoding, and local socket completion. The diagnostic has no private
or request-identifier field, synchronous diagnostic failure cannot change the result, and
traced/untraced success, refusal, timeout, thrown-boundary, and exact-response regressions pass
**25/25**. Primary **4753/4753**, auxiliaries **27/33/33**, and canonical `dev check` pass against
gate-built binary `sha256:7ba6d449…`. Generations 150/151 deploy local image
`sha256:2214fe3e…` and registry manifest `sha256:91cb4717…`; the unchanged retry rolls Provider
Worker revision 2 and proves its zero-restart Ready Service endpoint at `10.42.0.195:8600`. The
same connection timeout occurs with no `socket-ingress` diagnostic. Exact policy read-back admits
the Provider port only from namespace `provider-worker`, excluding the registered Lifecycle
Authority caller. Sprint `2.129` closes on that classification; register
`PROVIDER-WORKER-LIFECYCLE-AUTHORITY-INGRESS-DENIED-2026-08-31` under Sprint `2.130` before adding
the exact namespace-plus-Pod ingress peer. That policy correction now renders exactly alongside the
namespace-local lane; focused **26/26**, primary **4754/4754**, auxiliaries **27/33/33**, and
canonical `dev check` pass against the unchanged `sha256:7ba6d449…` binary. Generation 152 reads
back Provider NetworkPolicy generation 2 exactly but retains the connection timeout with no
`socket-ingress`. The reciprocal Lifecycle Authority policy has no Provider Worker egress entry.
Sprint `2.130` closes on its exact owned ingress read-back; register
`PROVIDER-WORKER-LIFECYCLE-AUTHORITY-EGRESS-DENIED-2026-08-31` under Sprint `2.131` before adding
the exact matching outbound destination. The reciprocal rule and paired-policy regression now pass
focused **26/26**, primary **4754/4754**, auxiliaries **27/33/33**, and canonical `dev check`;
Generation 153 reads back both exact policies and the request emits `socket-ingress`, crossing the
connection-timeout boundary. It completes every protected stage through credential binding, starts
capability execution, then the Provider container is OOM-killed with exit 137 under its exact 112
MiB limit; the client reports response timeout and the Pod restarts once. Sprint `2.131` closes.
Register `PROVIDER-WORKER-CAPABILITY-EXECUTION-OOM-112MIB-2026-08-31` under Sprint `2.132` before
changing the typed capacity owner.
The measured correction records a 74,052 KiB packaged-AWS-CLI peak, rounds it upward to one 80 MiB
slot, and physically serializes all Provider AWS/Pulumi launches across the four request workers and
independent readiness observer. The typed `100m / 176Mi` Guaranteed-QoS envelope proves a 64 MiB heap
cap plus 16 MiB native, 80 MiB child, 8 MiB kernel/cgroup, and 8 MiB safety terms while keeping the
portable standing-workload sum exactly within 12,800 MiB. Chart projection emits
`+RTS -M67108864 -RTS`; focused capacity/runtime/chart tests pass 17/17. The subsequent complete
primary suite passes 4758/4758 and its
auxiliary suites pass 27/33/33; canonical `dev check`, generated schema/docs/config validation, and
the gate-built binary at
`sha256:1c25a5648d10ea2ac5d04b5926ead7a4b73dbe1f29d54b5ef2e46eb4281e1145` are green. Both
installed integration entrypoints reproduce only Sprint `5.38`'s registered fake-tool drift at
55/63, with all four environment cases passing and none of the eight fixture-setup failures
reaching the Provider surface. At that local-validation checkpoint, only the unchanged supported
live proof remained Sprint `2.132` work.
Generation 154 builds/publishes/imports the corrected runtime as local image `sha256:0e6e645e...`,
registry manifest `sha256:cd334b28...`, and OCI manifest `sha256:72de7fd0...`, then exits at the
expected Authority rollout-transition timeout. Unchanged Generation 155 deploys Provider Worker
generation 3 with the exact 176 MiB/64 MiB-heap projection, completes capability execution and
socket completion with zero restarts, and closes Sprint `2.132`. Its 10.40-second observed response
exceeds Lifecycle Authority's generic 10-second Provider HTTP client budget even though the typed
child schedule is finite at five minutes. Register
`PROVIDER-WORKER-RESPONSE-AFTER-DEFAULT-HTTP-DEADLINE-2026-08-31` under Sprint `2.133` before
changing that Provider-specific transport budget.
The capacity-level correction caps the configurable Provider child schedule at 300 seconds and
derives only the Lifecycle Authority Provider client's response timeout as that maximum plus 30
seconds of bounded protocol overhead. The generic ten-second default and sibling clients stay
unchanged; focused runtime-memory/transport regressions pass 18/18.
The complete primary suite passes 4759/4759 and auxiliaries 27/33/33; generated
schemas/docs/config and canonical `dev check` are green at exact binary
`sha256:3895099483b8a08616bde0ef734a8168cdee913622313c59c2cdea6778931a2b`. Only the
unchanged-command live proof remains Sprint `2.133` work.
Generation 156 builds local image `sha256:d15dc2f...` in 1138.6 seconds, publishes registry
manifest `sha256:0c7dcb85...`, imports OCI manifest `sha256:923b1011...` in 88.6 seconds, and
removes only Generation 154's superseded local image. Lifecycle Authority rolls onto the new image,
then the command reaches the expected rollout-transition config observation timeout. Unchanged
Generation 157 reuses those exact identities, reads back the current Authority config, and runs
Provider Worker deployment generation 4 Ready with zero restarts on the exact 176 MiB/64 MiB-heap
projection. The protected request enters at 21:00:44.290Z, completes capability execution at
21:00:51.946Z, and completes its socket write at 21:00:51.950Z. Lifecycle Authority receives the
response, the reconcile advances through Gateway and TLS-retention, and the unchanged command exits
0. Sprint `2.133` and Phase 2 reclose; execution advances numerically to Sprint `5.38`'s registered
fake-tool fixture drift.
The same 55/63 installed-suite evidence also identifies a distinct fake Docker boundary: the RKE2
fixture rejects production's machine-formatted dangling-runtime-image inventory because its
`docker image` arm implements only `inspect`. Register
`FAKE-RKE2-DOCKER-RUNTIME-RETENTION-INVENTORY-2026-08-31` under Sprint `5.39` before changing that
interpreter; Sprint `5.38` remains first and owns only the earlier Helm-status projection.
Sprint `5.38` makes the generic fake derive canonical deployed/absent status from its explicit
inventory and makes the RKE2 fake return exact non-Harbor absence while preserving Harbor's state
transition. Its installed-boundary case passes 1/1; both complete entrypoints improve from 55/63 to
57/63, with all six remaining failures carrying only Sprint `5.39`'s registered retention
diagnostic. Primary 4759/4759, auxiliaries 27/33/33, and canonical `dev check` pass. Sprint `5.38`
closes and execution advances to `5.39`.
The Sprint-`5.39` fake inventory correction removes one explicitly seeded canonical managed image,
reads exact absence back, and advances the installed RKE2 reconcile through Lifecycle Authority.
The later Credential Provisioner substrate observation invokes `kubectl get --filename=-
--output=json --ignore-not-found=true`; the fake returns exit-zero empty output, which production
correctly refuses as invalid JSON. Register
`FAKE-RKE2-CREDENTIAL-PROVISIONER-SUBSTRATE-OBSERVATION-EMPTY-2026-08-31` under Sprint `5.40`
before changing that fake Kubernetes projection.
Sprint `5.39` closes with a focused 1/1 process-boundary proof over production's exact inventory
arguments and classifier. Both installed entrypoints remain 57/63 only because all six affected
cases advance to Sprint `5.40`'s registered observation refusal; all four environment cases pass.
Primary 4759/4759, auxiliaries 27/33/33, and canonical `dev check` pass. Execution advances to
Sprint `5.40`.
The Sprint-`5.40` stored Kubernetes read-back admits the exact nine-object substrate and advances
the installed reconcile to Authority Backup. Production's next independent image observation asks
for `docker image inspect --format {{json .RepoDigests}}`; the fake returns the same plain config
digest it uses for `{{.Id}}`, so no repository manifest digest can be selected. Register
`FAKE-RKE2-DOCKER-REPOSITORY-MANIFEST-INVENTORY-2026-08-31` under Sprint `5.41` before changing
that fake projection.
Sprint `5.40` closes with a focused 1/1 process-boundary proof of absent refusal, stored exact
apply/read-back, production-comparator admission, and malformed refusal. Both installed entrypoints
remain 57/63 only because every affected case advances to Sprint `5.41`; all four environment cases
pass. Primary 4759/4759, auxiliaries 27/33/33, and canonical `dev check` pass. Execution advances
to Sprint `5.41`.
The Sprint-`5.41` format-specific fake image observations select the exact repository manifest and
advance the installed reconcile to Authority Backup. The fake port-forward recognizes only the
obsolete `service/authority-backup` target while production requests `deployment/authority-backup`;
the exact request enters the silent generic arm with neither server nor acknowledgement. The
production client therefore refuses before HTTP and exhausts bounded liveness retry with `startup
acknowledgement timed out`. Register
`FAKE-RKE2-AUTHORITY-BACKUP-PORT-FORWARD-ACK-MISSING-2026-08-31` under Sprint `5.42` before
changing that fake projection.
Sprint `5.41` closes with a focused 1/1 process-boundary proof of distinct config and repository
manifest observations. Both installed entrypoints remain 57/63 only because all six affected cases
advance to Sprint `5.42`; every unaffected case and all four environment cases pass. Primary
4759/4759, auxiliaries 27/33/33, and canonical `dev check` pass. Execution advances to Sprint
`5.42`.
The Sprint-`5.42` exact target and acknowledgement cross their boundary, but the fake emits its
line before the fixture listener is bound. Production's immediate post-ack HTTP probe correctly
gets connection refused and bounded retry ends at the same liveness class. Register
`FAKE-RKE2-AUTHORITY-BACKUP-ACK-BEFORE-LISTENER-2026-08-31` under Sprint `5.43` before changing
fake startup ordering.
Sprint `5.42` closes with a focused 1/1 process-boundary proof of the exact Deployment target,
derived port mapping, production acknowledgement classification, and obsolete Service-target
refusal. Both installed entrypoints remain 57/63 only because all six affected cases advance to
Sprint `5.43`; every unaffected case and all four environment cases pass. Primary 4759/4759,
auxiliaries 27/33/33, and canonical `dev check` pass. Execution advances to Sprint `5.43`.
Sprint `5.43` closes the final fixture boundary: the owned fixture-server child proves exact
loopback readiness before acknowledgement, the first post-ack request succeeds, and teardown waits
for child exit. Focused evidence passes 1/1, the full RKE2 case passes 1/1, both installed
entrypoints pass 63/63, primary 4759/4759 and auxiliaries 27/33/33 pass, and canonical `dev check`
passes. Phase 5 recloses and execution advances to Sprint `6.5`.
Generation 124 starts after explicit 12:26:38 EDT admission and builds/publishes/imports
`sha256:17e9bde4…`, `sha256:def7f3fa…`, and `sha256:d2a4d6d8…` in 995.5 and 153.6 seconds, deleting
only Generation 123's local image. Current root session `root-session-9c54db6a…` and digest
`a5756119…` remain exact. The Target Job and container now start at 12:52:00/12:52:01, positively
proving the runtime-identity fix; cleanup begins at 12:54:28. The terminal nevertheless remains
`execution-failed/recovery-remint-ambiguous/target-delivery-failed/worker/observation-failed`.
Register `TARGET-WORKER-POD-OBSERVATION-FAILED-AFTER-START-2026-08-30` and classify only the closed
value-free observation cause before behavior changes. Postflight is clean at NetworkPolicy
generation 46, no one-shot residue, exact-image Ready retained workloads, a pressure/taint-free
Ready node, and 43 GiB free. The conservative fence runs through 13:24:54 EDT; no successor is
admitted before 13:24:55.
The local diagnostic nests one closed cause below `observation-failed`: Pod API exit/invalid list,
multiple Pods, exact binding/container/status/runtime-image/annotation refusals, named
ServiceAccount API/response/name/namespace/UID refusals, or `other`. An exhaustive table proves
unique tokens and that private response, identity, annotation-name, and subprocess details cannot
cross the terminal. Retry, observation, attestation, permit, attach, cleanup, and receipt behavior
are unchanged. Focused Sprint-2.116 passes 22/22, exact AWS-admin Authority 42/42, full primary
4737/4737, and auxiliary suites 27/33/31. Fourmolu, HLint, documentation, repository-policy, and
diff gates pass; the canonical aggregate gate exits 0. Its gate-built and installed executable is
byte-identical at `sha256:d1329b57…`.
The generation-59 control reaches its 30-minute deadline still live, exact-image, zero-restart, and
0/1 Ready; the supported command exits 1 and retains that non-terminal release. The refreshed
correction deployment follows.
Sprints 2.54
through 2.75, 2.76, 2.81, and 2.82 are closed as recorded in
their own rows.
Phase 3 is reclosed on Sprint 3.45: the intentionally no-wait Broker Helm apply selects a finite
60-attempt revision-observation window covering the measured 14-second RKE2 controller delay
without weakening its exact predicate; generation 32 crossed it live and reached Vault baseline.
Sprint 3.44 remains closed: its live retry observed `Complete` before
explicit deletion, reached registry Ready, and proceeded into image publication. Its prior reclose
on Sprint 3.43 remains: the
rebuilt, zero-restart ready Broker Pod carries the exact
minio.prodbox.svc.cluster.local:9000 Service endpoint. The long rows below retain their historical
result narratives. -->
<!-- Prior Phase 3 status: reclosed on Sprint 3.40 (2026-08-15). The pre-Vault Broker graph gate
uses an observed-revision admission and the live reconcile crossed it into Vault lifecycle. -->
<!-- Prior Phase 4 status: reclosed on Sprint 4.83 (2026-08-15). Pod pulls use declared tags;
Kubernetes imageID observations, not the authored specs, attest the separately resolved OCI config
digest. The detailed row retains the registration history inline. -->
| 0 | Planning and Documentation Topology | ✅ Reclosed on `0.17`: the Foundation Epoch is adopted on top of the `0.16` control-plane correction, Standard P carries the interim escape-path guard, and Sprints `1.61`/`1.62` are shrink-rescoped. Sprint `0.18` adds the configurable certificate-scope governance surface on that same documentation surface (an additional governance sprint, no further reclose). | Documentation lint/check and canonical quality gate; no runtime dependency. |
| 1 | Runtime, CLI, Config, and Pulumi Foundations | ✅ **Reclosed on Sprint `1.92` (2026-08-22)** — Tier-0 generation now leaves deployment-varying values unauthored, one validation boundary retains an opaque served-host/cluster/machine/Vault/MinIO projection, and daemon startup cannot reconstruct a deployment when its authored config is absent. The compiled served-host answer, production context/topology seeds, and false `acme.server` / `context.minio_bucket` fields are deleted; ZeroSSL and the generic state bucket each have one compiled declaration, guarded by a mutation-proven ownership gate. Consumer adoption closed independently in Sprints `2.52`, `3.42`, `4.90`, and `5.37`. Previously ✅ **Reclosed on Sprint `1.91` (2026-08-20)** — an own-surface reopen (Standard A/N) on the Tier-0 coordinate and `dev check` surfaces this phase owns. `defaultConfigFile` seeded `aws.region` with a literal region while seeding every sibling operator coordinate empty, so the three fail-closed rules that already refuse an absent region — two in `Prodbox.Settings`, one in `Prodbox.CLI.Vault` — could never fire, and a misconfigured deployment provisioned where nobody chose. `1.91` empties the seed, deletes the prompt default that would otherwise have re-invented the value one layer up, threads the configured SES capture bucket into the printed IAM policy so the grant an operator pastes into IAM names the bucket the deployment owns, collapses three constants stating one MinIO signing region and two stating one global-service tagging region, and adds `checkAwsCoordinateLiterals` — a register-or-fail bijection over every AWS-region-shaped literal in `src/` and `app/`, measured at 22 (file, value) pairs with zero false positives and proven to refuse against the live binary rather than only to pass. Previously ✅ **Reclosed on Sprint `1.89` (2026-08-13)** — `1.89` gave the Tier-0 coordinates a retained parse: `ValidatedCoordinates` on `ValidatedSettings`, built by `validateConfig` from nine smart-constructed types, with the Dhall wire format byte-identical so no generated-config identity change occurs. It closes the ledger's last unowned row. Nine coordinates were *decided and discarded*; five were **never decided at all**, including `route53.zone_id` — less defended than the structurally identical `aws_substrate.hosted_zone_id` — and `pulumi_state_backend.region`, which had no rule anywhere while both its siblings did. Seven use-site re-decisions are deleted rather than moved, because the narrowed types have no empty inhabitant. Two drafts were refused by the repository itself: a both-or-neither ACME rule that rejects `prodbox config generate`'s own output, and a `dev check` rule whose first run flagged a correct read (fixed by renaming a binding, not weakening the rule). Prior: ✅ **Reclosed on Sprints `1.87` and `1.88` (2026-08-13)** — `1.88` gave `ValidatedSettings` one production constructor: the single site that forged one without running `validateConfig` (and got its resource plan by `error`-ing) is deleted by narrowing `resourceStatusLines` to the two fields it read, and a `dev check` rule keying on field *assignment* keeps the seam closed for record updates as well as constructions. The bound is stated — a compiled rule over a source region, not a property of the type. `1.87` — an own-surface reopen closing the re-scoped successor `1.84` registered against itself. `substratePublicRouteUrl` rendered `https:///path` for a substrate declaring no served host; the renderers now take the `ValidatedServedHost` that `validateConfig` already builds, whose `Fqdn` is minted only by `mkFqdn`, so the empty rendering is **unconstructible** rather than refused, and `substratePublicFqdn` is **deleted**. The row prescribed a resolved `String`, which would have left `""` well-typed and the refusal in caller discipline. Its premise was also wrong: all 16 sites resolve at eight points that already had an error channel, and nine functions stopped taking `ValidatedSettings`/`Substrate` entirely. Prior: ✅ **Reclosed on Sprint `1.84` (2026-08-12)** — an own-surface reopen closing the residual Sprint `1.83` registered against itself: `substratePublicFqdn` answered `""` where its own projection says "no served host". All six direct call sites refuse through `requireSubstratePublicFqdn`; the two pure renderers take a resolved host from an IO caller that resolves; the accessor is unexported so the empty string cannot gain a new caller. Deletion is deferred as its own re-scoped row (`substratePublicRouteUrl`, ~10 sites) rather than folded into one coupled change. Prior: ✅ Reclosed on `1.67`: Sprints `1.61`–`1.66` are Done, and generic Kubernetes reachability now follows the selected substrate kubeconfig through `ToolKubectl` + authoritative `kubectl cluster-info` without importing home-local RKE2 file/service prerequisites. | Pure capability-kind, graph, deadline, capacity, object-store protocol, Vault-session, and prerequisite transitive-closure properties. |
| 2 | Gateway Runtime and DNS Ownership | 🔄 **Reopened on Sprint `2.109` (2026-08-28).** Sprint `2.108` is Done and live-proven: generation 73 renews the exact expired prepared state while retaining journal identity and reaches permit-bound Job creation. Exact read-only observation then proves the fixed Credential Provisioner namespace, ServiceAccounts, isolation policy, and controller permissions are absent. Sprint `2.109` makes that execution substrate an ordered, idempotent, read-back-proven component before genesis on the mandatory retained local control plane consumed by both target selections; Jobs remain ephemeral permit effects and never move to EKS. Historical Phase-2 closure records remain in the sprint records. | Pure exact-manifest and plan-order proofs, stateful apply/read-back/idempotence/refusal tests, full local gate, then exact-image Job creation and attestation. |
| 3 | Chart Platform and Public Workload Delivery | ✅ **Reclosed on Sprint `3.45` (2026-08-26)** — the intentionally no-wait Broker Helm apply now selects a finite 60-attempt exact Deployment-revision observer; generation 32 crossed it live, ready 1/1 with zero restarts, and the same reconcile reached Vault baseline without an operator retry. Every other component retains the three-attempt policy. Sprint `3.44` remains closed and live-proven: its waiter observed the registry bootstrap Job reach `Complete` before explicit deletion, brought the registry to Ready, and advanced into image publication. Prior: 🔄 **Reopened on Sprint `3.43` (2026-08-23)** — the first Sprint `6.5` live preflight proved that `3.42` projected the operator host's loopback MinIO address into a Pod, where loopback names the Pod itself. The correction gives the in-cluster Service identity one compiled owner and retains the authored endpoint for host execution; live local reconcile is the closure gate. Prior: ✅ **Reclosed on Sprint `3.42` (2026-08-23)** — every chart-rendered Gateway/Broker/Authority store projects the validated deployment endpoint, the generic state bucket imports its one object-store identity, and public-edge inventory narration evaluates the supplied served host. Two-context structural/mutation proofs, chart lint, unit tests, and `dev check` are green. Prior: ✅ **Reclosed on Sprint `3.41` (2026-08-17)** — the own-surface reopen for the bootstrap-owned teardown control plane closes. The teardown caller identity's independence from Gateway and every application namespace is now a *derived* property rather than an authoring convention: each recovery-plane resource resolves to the release and namespace owning its lifetime through the one chart-name registry, and the deletion scope is the complement of the recovery closure over that same registry, so a new application chart extends the scope without editing the projection. The absent-substrate artifact gap the reopen was opened on is answered by naming it rather than papering over it — a versioned, architecture-specific retained inventory with a closed kind universe, and a repair matrix whose absent arm refuses by construction, naming the complete missing set, while nothing is retained. The ordinary install path's `curl https://get.rke2.io` remains the steady-state installer; what changed is that no *recovery* path may reach for it. Retaining and GC-ing the bytes is lifecycle execution and moved to Sprint `4.86`. Prior: ✅ **Reclosed on Sprint `3.38` (2026-08-15)** — `cluster reconcile` was building and pushing a new runtime image and leaving the in-cluster workload on the previous one, because `deployChartPlan` filtered releases on `helm list` status: an all-`deployed` chart root produced an empty deploy set and a **success report with no helm invocation behind it**. `helm list` carries presence and health and no revision, so the predicate answered a different question from the one it was consumed for — the same § 24 shape as Sprint `2.51`'s own defect. The filter is deleted rather than made conditional, because `helm upgrade --install` is itself the idempotent convergence operation. Live-proven: generation `1`→`2`, annotation to the image the run built, a new ReplicaSet, and `bootstrap-broker.v2` beside `v1`. Prior — taking Sprint `2.51`'s live proof exposed that `cluster reconcile` builds and pushes a new runtime image and leaves the in-cluster Bootstrap Broker running the previous one: the Deployment was at `metadata.generation: 1` from the previous day with a 10h-old Pod whose `imageID` was the old image, and its rollout annotation held a digest the Docker daemon no longer has. Generation `1` means the object was never modified, so this is a rollout never requested rather than one that failed. An Active sprint working a `Pending Removal` row is not a reopen (Standard N). Prior: ✅ **Reclosed on Sprints `3.36` and `3.37` (2026-08-13)** — **Sprints `3.36` ✅ and `3.37` ✅**, both found by the **first live Standard-P qualification run** — the first time this plan has gained work from running the system rather than reading it. `prodbox test all --substrate home-local` failed deterministically, twice, at the cert-manager mirror. **`3.36`**: `mirrorHostArchitectureTarget` passed no platform to `docker pull`/`docker push`, so under the containerd image store it published the whole manifest **index**; for a multi-architecture upstream that index names platforms whose blobs were never fetched. Invisible until now because **every one of the 17 mirror targets that had published before it presents a single platform locally** (the registry carries 24 entries in total). The asymmetry is the finding: the custom-image *build* path beside it has always resolved `supportedHostArchitecture`, and the mirror path — named for it — never consulted it. The sprint **records that it has no successful-publish proof**, because the working mirrors were already in the registry and were skipped. **`3.37`** is a sprint whose entire content is a measurement that exonerates this repository: five hypotheses tested and discarded before a pin moved — stale local content (purged, re-pulled, still fails), multi-arch in general (`alpine:3.20`, identical index shape, fine), quay.io (`v1.16.1` same repo, fine), cert-manager (`v1.16.3/4/5`, `v1.17.1`, all fine), controller-only (all five `v1.16.2` images fail). A specific upstream release is unpublishable and no harness work would have fixed it; the pin moves to `v1.17.1`, which **invalidates any prior component-image identity** since `certManagerChartVersion` is derived from the controller tag. One unowned residual recorded: cert-manager is the only mirrored platform component with **no fallback source**, and `3.37` is the proof that this matters. Prior reclose on Sprint `3.35` (2026-08-13) — an own-surface reopen giving the control-plane listen port and the in-cluster role-URL shape one compiled owner (`Prodbox.ControlPlane.ListenPort`), enforced by `checkControlPlaneListenPortOwner` and mutation-proven against the binder. The row's open question is answered by measurement: `runControlPlaneServer` binds without consulting the role it is handed, so the five per-role constants could never have diverged. `ChartStatics.hs`, which called the port operator-chosen deployment configuration while the binder hardcoded it, is corrected under Standard C. Rendered output byte-identical. Prior: ✅ **Reclosed 2026-08-11 on Sprint `3.34` (Standard A/N)** — the Kubernetes API egress coordinate has one compiled owner observed from `endpoints/kubernetes` (post-DNAT address and port together), both charts bind it through `.Values`, and the chart-lint region widens to every repo-owned template under a closed port-key set; its first run named 77 findings, reconciling with the 79 measured less the two already migrated. `dev check` 0, `test unit` 0. Validation 5 stays 🧪 Standard-O pending on Sprint `2.43`. Prior state — 🔄 **Reopened 2026-08-10 on Sprint `3.34` (Standard A/N)** — an own-surface reopen on the chart platform and chart lint. The Kubernetes API egress coordinate has no compiled owner, so three sites each author their own `443` while the API endpoint listens on `6443` post-DNAT; `3.34` derives it from `endpoints/kubernetes` and widens the chart lint to every repo-owned template, closing a region in which no gate reads a `networkpolicy.yaml` for content. Edits a live production rendering path. Prior reclose on Sprint `3.33` (2026-08-09). ✅ Reclosed 2026-07-25. Sprint `3.26` renders the physically separated control-plane workloads; `3.28`/`3.29` single-source resource rendering and durable PVC sizes; `3.27` derives namespace admission from validated demand and placement. | Deterministic chart rendering, identity/policy/resource/probe lint, negative topology fixtures, retained-volume plans, unit/integration suites, and `prodbox dev check`. |
| 4 | Lifecycle Hardening, Pulumi Decoupling, and Python Removal | ✅ **Reclosed on Sprint `4.90` (2026-08-23)** — host and Pulumi Vault probes project the validated deployment context; retained lifecycle resolution refuses exact cluster/Vault mismatch before effects; lower gates consume sealed Tier-0 basics; and one compiled state-bucket declaration feeds every consumer. The address/id/default fallbacks and production endpoint-changing test seams are deleted, with two-context, mismatch, mutation, unit, and CLI proof green. Deployment qualification remains pending under Standard P. Prior: ✅ **Phase stays closed; Sprints `4.84` ✅ closed 2026-08-17, `4.85` ✅ 2026-08-18, and `4.86` ✅ + `4.88` ✅ 2026-08-20** — Sprint `4.88` closed a defect the doctrine already forbade and a test already pinned: `cluster delete --cascade --yes` with no RKE2 install exited 0 having reached no phase, because the short-circuit was selected before the delete mode was consulted — and local RKE2 absence is not per-run AWS absence. The terminal arm is now a total table over the (mode, presence) product with exactly one no-install success arm, belonging to local-only delete; the cascade's no-install arm names the durable cleanup run namespace it could not reach and its `RecoveryPlaneNotEstablished` disposition and exits non-zero. The retained-state notice became a total function over the terminal arms, so only an arm carrying a completion receipt or an explicit local-only uninstall says the root is preserved by what it did — the legacy cascade carries none, and a new arm with no narration fails to compile. Sprint `4.86` closed with the two composition roots the descriptor-bound dispatcher needed and the drive over them. The **cloud runtime had no production composition at all**: `mkCloudRuntime` normalizes four interpreters and nothing in `src/` built one, so the dispatcher admitted a closed cascade host runtime it could construct and a closed cloud runtime it could not; and **two durable records were unreachable from a host**, because the ownership manifest decision and the AWS stack creation binding are each keyed by an authority identity only their repository module can derive while both host-reachable clients take that identity as an argument. The **candidate entrypoint** then drives the total dispatcher over a durable descriptor-bound run, from a plan that is a function of the declared cascade identity — the initial lease is a *declared* window rather than a clock sample, so a re-entry replays the run the Authority already holds instead of admitting a second one for the same host. Landing it exposed that the **durable-cascade entry protocol was on the wrong side of a boundary**: capturing the descriptor, preparing the host intent before any mutation, observing-or-creating, claiming, attaching the primary outcome, and reading the terminal report back are what any caller of the protocol must do, and the Sprint-`4.85` harness-namespace gate refused the first production caller outright, so the module moved to `Prodbox.Lifecycle.CleanupRunEntry` rather than the allowlist being widened. The seven validation items closed with a **surface-indexed `LocalUninstallEvidence`** — the type stood for the cascade and local-only surfaces at once, so only a caller's discipline stopped a local-only host observation from claiming a cascade converged — and a **composed frozen run** measuring that an unavailable Authority, three unobservable per-stack observations, and one returned two-tag mapping do not contaminate each other. Item 7's installed-CLI half was re-scoped to Sprint `6.5` under Standard N, because this sprint activates no public writer to trace. Earlier in the sprint: retained-artifact custody landed 2026-08-18: Sprint `3.41` could say exactly which artifacts an absent-substrate repair needed and the repository retained none of them, so that arm of the matrix could only refuse. Custody derives one plan from the validated inventory and one exact store listing, classifying every entry and every observed member exactly once, and it treats the inventory as the authority and a pinned-archive source as a transport — delivered bytes are discarded rather than placed unless they hash to the digest the inventory already pinned, checked once at catalog binding and again at execution. Convergence is read back from a fresh listing alone, so a successful delivery response is not retention, and the store is phantom-indexed by how its root was obtained so only an Authority-bound root can replace or collect. Later the same day `4.86` landed the consumer that makes custody load-bearing: `Prodbox.Lifecycle.Teardown.RecoveryRepairExecution` is the only surface that executes a rendered repair, and the executable value has no constructor reachable from a rendered plan alone — the plan is joined against an observation of the retained store, and only a join in which every named artifact is present and hashes to its pinned digest yields one. A refusal carries the custody plan that closes it and distinguishes the two cases where no acquisition can: an artifact the inventory never declares has no pinned digest to check a delivery against, and an unlistable store decides neither retention nor drift. Because repair steps are sequentially dependent, application stops at the first failure and carries the unattempted tail rather than producing further failures describing the wrong boundary, and substrate convergence is read from a fresh observation alone. A third increment landed cascade Stage C: every value doctrine § 5b node 7 names existed as a type and nothing performed the sequence, so no production cascade could reach `ReadyToUninstallEvidence`. `Prodbox.Lifecycle.Teardown.PreUninstallReadiness` commits the pre-uninstall report, reads it back through a boundary that is deliberately separate from the writer, obtains the one-shot permit, and composes readiness — with the read-back running after every commit outcome including a reported refusal, so a success that left nothing durable and a refusal that had already landed are separated by the observation rather than by the response, and a report identity that drifted refuses before the Authority is asked to sign anything. A fourth increment joined the cascade's terminal node: the marker observer is forbidden from naming the absence proof and the constructor that mints it is private, so an exact host observation's absent arm had nowhere to go; `Prodbox.Lifecycle.HostCleanupLocalAbsence` is that join, scoping the observation from the durable host-cleanup record rather than from the readiness so the constructor compares two independent sources, and keeping still-installed and unobservable as distinct answers. A fifth increment gave the cascade's terminal arm a producer: the retained matcher catalog, query catalog, classification, and region-bounded verdict all existed unassembled, so `Prodbox.Lifecycle.Teardown.CascadeTerminalAudit` issues each catalog query separately and unions by ARN — the Tagging API intersects filters inside one call, which was the Sprint-`4.77` defect — treats an unanswered query as a blind spot that prevents a clean verdict while still classifying what came back, refuses the audit outright when two rows disagree about one ARN, and derives its scope through the same function the evidence constructor checks against. A sixth increment gave the terminal node's other arm a producer: doctrine § 5b node 8 named `prepareLocalCompletion` and the receipt it mints, and neither existed, so a cascade that had proved exact host absence still could not close its durable run. `Prodbox.Lifecycle.HostCleanupCompletion` binds the signed permit and the observed uninstall evidence to the stable local-completion operation reference, appends that entry to the preserved journal under an exclusive link keyed by the digest of the reference — so a rerun after a lost append response finds its own entry rather than writing a second one, and a present entry that differs is a conflict rather than an overwrite — and separately observes it back, reading the journal rather than the append's answer, with every field of the resulting read-back decoded from the durable bytes so the runner's binding comparison stays a comparison of two independent sources. A seventh increment gave the cascade's credential-disposition proof a producer: its constructor existed and nothing produced its input, so the only inhabitant in the repository was the fixture's authored `Disposed`. `Prodbox.Lifecycle.Teardown.CascadeCredentialDisposition` derives the disposal set from the credential inventory as exactly the run-scoped classes, with the retained set as its complement so no class is absent from both, which makes the Lifecycle-provider credential's retention a consequence of the partition rather than a second rule — a cascade that revoked it would fence the terminal audit it had just run. A credential observed still present is outstanding whatever the other observations did, an unanswered class decides unobservable rather than disposition, and an empty disposal set is a refusal rather than a vacuous proof. An eighth increment joined the recovery repair to the host runner: Sprint `3.41` said what a repair is and Sprint `4.86` said how to admit and run one, and neither reached the runner, so the destructive host boundary could not re-establish the plane it depends on. `Prodbox.Lifecycle.HostCleanupRecoveryPlane` observes the substrate, admits the repair its observed state needs, applies it, and reads the plane back — and the re-establishment deliberately never reports availability, which only the separate read-back from a fresh observation decides. An unobserved substrate selects no repair at all, since a plan is rendered for an observed state, and admission precedes every boundary call so an unadmittable repair is refused rather than half-run. A ninth increment gave the runner's three Lifecycle-Authority effect pairs a production answer: nothing in the repository stored a pre-uninstall readiness at the Authority at all, so accepting it, re-establishing the Authority after the destructive step, and reconciling the durable cleanup run could only ever be exercised against fakes. `Prodbox.ControlPlane.HostCleanupReadinessRepository` is the retained namespace, named from the `CleanupRunId` alone with the only write being into an empty slot, so a second different readiness under one run is a conflict rather than a second key while an exact replay is a success; `Prodbox.Lifecycle.HostCleanupAuthorityArms` is the join, and it answers the acceptance read-back and the post-re-establishment read-back with the same observation asked at two times, so an Authority restored without the readiness it accepted cannot satisfy the runner. Re-establishment reports only what the attempt did and awaits admission only after a successful restore, and the run reconciliation begins and completes the local-uninstall node under the one deterministic attempt derivation, now shared with the durable cleanup driver rather than copied. Prior: Sprint `4.85` closed by retiring all eight `OperationalCredentialDispositionBlocker`s. Four of them rested on a `TypeLevelAbsence` — a "no constructor exists" fact no value could witness, so a reason that stopped being true would have gone on justifying the same omission — and each was closed by *building* the missing capability and deriving the blocker from it: an authenticated route that issues the Cascade-audit freeze, the terminal escape audit classified as a Lifecycle-provider consumer, a canonical revocation read-back decision both revocation paths decide through, the operational surface compiling its own credential revocation, total decommission ordering that disposition strictly after its terminal audit, and a retained Provider operation naming the cleanup operation that authorized it. `OperationalTeardown` now mints its own completion witness over an obligation that is no longer empty. Earlier in the sprint, three increments landed 2026-08-18. The third landed the **home-substrate uninstall**: the compiled program had emitted `decommission/uninstall-local` and its read-back since the program algebra landed and no runner executed either, so a total decommission destroyed every AWS resource class and left local RKE2 installed. The terminal phase is now an ordered closed enumeration whose order is *measured* against the compiled program by a two-sided reachability relation rather than asserted twice. The second put the **final no-retention escape audit inside the receipt graph**: Sprint `4.76`'s terminal tag sweep ran after `runPreparedNuke` had already returned success, so a crash there left a run converged on paper with its only no-escape proof never taken and nothing left in the plan to resume. It is now `FinalNoRetentionAudit`, the graph's unique terminal, read-only by construction, with the shared object bucket demoted to last *resource deletion* — the order the compiled `TotalDecommission` program already emits. It is the first of twenty-one tags to measure `CompiledProgramAndRunner`, and the out-of-band tail is deleted. The first increment closed the surfaces that made adding such a node silently incomplete: the decommission node universe was written down six times in three naming schemes and joined nowhere, so the previous session's "adding a node is a change the verifier cannot ignore" held on exactly one of them. The signed interpreter-registry identity (digested into `VerifierMetadata`, guarded only by a non-empty-literal test no arm could fail), the Authority's own production plan in `ControlPlane.Runtime` — the *producer*, whose disagreement with the verifier would surface only after the point-of-no-return confirmation — and the `NODE=` lines of the `--dry-run` plan an operator approves are now derivations of the closed enumeration, all three byte-identical to what they replaced. Prior: two Sprint-`4.85` increments landed 2026-08-17 after `4.84`'s closure: `Prodbox.Lifecycle.Teardown.RegisteredTargetExecutor` joins the typed registry to the production registered-target interpreter, so a descriptor with no executor can no longer be registered onto a surface that mints completion evidence — which had made the cascade unable to reach its terminal audit and the just-landed `ExplicitPerRun` completion minter unable to fire; and `Prodbox.Lifecycle.Decommission.ProgramTag` measures validation item 10's bidirectional parity, finding the compiled total-decommission program and the signed manifest runner **disjoint across all twenty-one semantic tags**. `4.84` delivered the exact-keyed observation algebra, the run-invariant registered-stack lifecycle generation and its durable join, the terminal retained matcher/query catalog, the region-bounded terminal-audit verdict, and both directions of that generation reachable from a host run. On closure it was re-scoped under Standard N: it had been holding a consumer conversion its own text said could only land inside Sprints `4.85`/`5.36`/`6.5`, which is a later-phase dependency the standard forbids and which left the whole queue unable to close; that conversion now belongs to the sprints owning the compositions it deletes. An Active sprint working a `Pending Removal` row is not a reopen (Standard N), so this phase stays ✅. Prior: **Sprint `4.83` 🔄 opened 2026-08-15** — a sweep for Sprint `2.51`'s defect found three further `repository@<digest>` Pod images with `imagePullPolicy: Always`, and **measured all three away**: `docker inspect .Id`, `.RepoDigests`, and the registry's `Docker-Content-Digest` agree, so the references are pullable. What survives is that they are pullable by host configuration rather than by contract (this host runs Docker's containerd image store, under which `.Id` is the manifest digest), plus a genuinely independent defect the sweep exposed — those three observers compare a declared reference against itself and hold no runtime-identity attestation, and `ContainerStatusDto` does not parse `imageID` at all. Prior: ✅ **Reclosed on Sprints `4.78`, `4.79`, and `4.80` (2026-08-13)** — the own-surface reopen on the observation-producer and destructive-cleanup surfaces closes, taking this phase's last three unowned rows. Nine prose classifiers become one anchored, probe-keyed owner; two destroy paths get opposite remedies for the same shape (report vs refuse), decided rather than defaulted; and the sweep's last skip arm is resolved from the substrate the cascade already infers, adding no requirement. Prior: -08-11 on Sprints `4.76`/`4.77` (Standard A/N)** — the own-surface reopen on the destructive lifecycle paths this phase owns closes. `4.76`: the cascade's four "cannot observe → absent" folds are each three-valued with the **uncertain arm as the default** — `ClusterProbe` reads a positive absence only from a recognised connection-establishment phrase, `inferCascadeSubstrate` releases the home branch only when every stack was observed absent, `reconcileAbsent` returns observed-absent and unobserved separately so an unresolved observation fails the aggregate, and the cascade folds six phase outcomes while still running every phase. The postflight sweep is fail-closed through one total `decideTagSweep`, and `prodbox nuke` gains the terminal sweep § 5/§ 6b assign it — whose **absence a unit case had asserted as an invariant**. `4.77`: one `--filters`/`--tag-filters` occurrence per call with the cluster and ownership sweeps issued as two calls unioned by ARN (the Tagging API ANDs `TagFilters`, so the intended OR was never one call), a client-side re-filter in the EBS reaper through a classifier that had no production caller, a fail-closed payload parse, and `--yes` gated at one site across all four destroy verbs with the quietness selector it had doubled as split out. Prior state — ✅ **Reclosed 2026-08-10 on Sprints `4.73`-`4.75`**, ending the own-surface reopen on the condition it existed to remove: no `Pending Removal` row on a Phase-`4` surface is unowned. `4.73` routes the SES DNS writer through the typed `DnsRecordProgram` under its own `LongLived` owner, with a total owner/type matrix, canonical CNAME/MX value forms, and a propagation barrier that keeps the batch's single wait; `4.74` gives the Vault CAS seam the `ModelBCas*`-style vocabulary and a build rule enforcing it, after finding four callers classifying wrongly where the row said none classified at all; `4.75` owns the authored control-plane service time and corrects the haddock that called it measured. Prior reclosures stand. | Pure capacity/admission and deadline folds, the owner/type matrix and CAS classifier as total pure functions, socket-pair proofs of the `429`/`408` replies with no listener, mutation exercises on the `dev check` gates, and the installed `cli` integration suite — no live infrastructure. The live Route 53 read-back and the control-plane measured profile remain Standard-O axes. |
| 5 | Canonical Test Suite | ✅ **Reclosed on Sprint `5.43` (2026-08-31).** Sprints `5.38`–`5.43` make the fake Helm, Docker retention/image identity, Kubernetes stored read-back, and Authority Backup forwarding boundaries project their exact production contracts. The Authority Backup fake proves its owned child listener ready before acknowledgement and waits for child exit on teardown. Focused immediate-probe and full-RKE2 cases pass; installed CLI and env each pass 63/63; primary/auxiliary and canonical development gates pass. | Exact fake-boundary regressions, installed CLI/env 63/63, full unit/auxiliary suites, docs/diff checks, and canonical `prodbox dev check`. |
| 6 | Final Clean-Room Rerun and Handoff | 🔄 Active on Sprint `6.5`: the typed replacement program, validation client, exact adapters, custody disposition, and compiled DNS-zone binding are complete; the public generic/home sole-writer cutover and its qualification-gated legacy removal are next. | Pure cutover/resume/rollback folds, installed fake traces, repository absence guards, unit/integration gates, then current-revision qualification under Standard P. |
| 7 | AWS Substrate Foundations | ✅ Reclosed on Sprint `7.38` (2026-08-23). Sprint `7.36` completed the exact native stack, IAM/controller-family, manifest/adoption, EKS-drain, audit, and revocation adapters; `7.37` completed the typed operator-authored AWS profile, signed provider-intent transport, Pulumi configuration path, and positive EKS desired-size consumer; `7.38` completed the graph/descriptor DNS-zone binding and legacy-v1 restart reader. Operational legacy-route removal remains qualification-gated. | Focused 4/4, unit 4589/4589 plus auxiliary components, installed CLI/environment 62/62 each, docs gates, and `dev check`; live Route 53 and current-revision deployment qualification remain pending. |
| 8 | Invited Email Authentication | ✅ Reclosed on Sprint `8.12` (2026-08-02): the durable SES workflow and non-partial invite fault/qualification artifact are code-locally complete; live qualification remains Standards O/P. | Invite 8/8, daemon lifecycle 27/27, unit 3067/3067, installed CLI/environment 55/55 twice, and `prodbox dev check` exit 0. |

## Historical Alignment Record

The 2026-08-15 trace is stable MISU counterexample `TEARDOWN-2026-08-15`: AWS audit succeeded with one
`ResourceTagMapping` for the retained bucket and its full two-tag set; Prodbox's decoder emitted
two internal rows and copied the global answer to three per-run identities whose exact observations
remained `Unobservable`. No drain request reached Kubernetes and no destroy reached a provider
effect. The preliminary caller observation's cause/API reach is unknown because stderr was
discarded. All production-changing rows remain deployment-qualification pending.

### Prior alignment record

The prior per-phase closure state and Independent Validation are the long table above. The dated reopen/closure
history is consolidated in [README.md → Historical Closure Record](README.md#historical-closure-record),
and per-sprint detail lives in the phase documents ([phase-0](phase-0-planning-documentation.md) …
[phase-8](phase-8-email-invite-auth.md)) — this section is not a per-sprint changelog (Standard D).

**Prior head state (2026-08-14 — every phase was closed; one sprint was open, and a live
proof rather than an unfinished deliverable is what opened it):**

- **Sprints `2.48` ✅ and `2.50` ✅ closed, and Sprint `2.51` 🔄 opened because closing them let the
  bring-up reach a defect nothing had yet seen.** All three sit on Phase `2` surfaces without
  reopening Phase `2` — a sprint working a `Pending Removal` row is not a reopen (Standard N).
  Evidence: `dev check` 0, `test unit` 0 (**3468** + 27 + 33 + 27), `test integration cli` **57/57**,
  `test integration env` **57/57**. Ledger: **pending 66 → 65, unowned 2 → 2, completed 299 → 301**.
- **Sprint `2.50`'s live proof passed on the arm it changed, and the proof is a durable object rather
  than an absent error.** The stuck checkpoint was rewritten from store version 2 at fence generation
  7 to version 4 at generation 13 — `driveSecretWorker` rolling a superseded pre-receipt checkpoint,
  which nothing else in the tree does. The run then failed further along, at Sprint `2.51`'s defect:
  the Broker pins its worker Pod's image to the controller's `imageID`, a **config** digest on a
  locally-built host, while a registry can only resolve a **manifest** digest. **A config digest and a
  manifest digest are the same sixty-four hex characters**, so no smart constructor over the text
  could have separated them — [§ 24](../documents/engineering/chaos_hardening_doctrine.md) exactly, an
  observation naming the container runtime's layer while consumed as the registry's.
- **Sprint `2.50` refuted this plan's own description of the object it was registered against, by
  decoding it.** The row said the stuck secret-worker checkpoint was "Vault-enveloped and its
  completion state has not been decoded" — and gave that as the reason its failing arm could not yet
  be named. Both halves were wrong: the bootstrap store's `StoredEnvelope` is canonical CBOR over
  `SecretFreeWorkerRequest`, inlined in the MinIO object and readable with **no Vault session**, on a
  host whose Vault is uninitialized. The caution had made the decode look impossible on exactly the
  host where it was trivial.
- **The decode corrected a count, which is this plan's recurring defect at a third surface.** Two
  compared binding fields cannot repeat across invocations, said the plan; it is **three** — the
  operation deadline is `acceptedAt + budget`. **The reason nobody caught it is the sprint's other
  deliverable**, which makes this the first instance of the payload-free-refusal collapse whose cost
  is demonstrable rather than argued: one constructor produced at **five** distinct sites, so no run
  could ever have reported which fields disagreed. Fifth instance of the shape Sprints `2.46`–`2.49`
  each closed one layer up.
- **The remedy is narrower than any of the three options registered, and the bound that scoped the
  sprint chose it rather than being argued across.** A checkpoint is a *result* record — but that is
  a statement about checkpoints which **carry** a result, and the stuck one is
  `InternalNoWorkerReceipt`. The roll arm widened, bounded three ways: pre-receipt only, a **strictly
  older** fence generation only, and the predecessor's worker **destroyed** by a UID-preconditioned
  delete rather than observed absent — stronger than Sprint `2.47`'s absence observation, because it
  causes absence instead of inferring it.
- **Sprint `2.48` closed the ledger row it owned rather than letting it outlive its owner**, which is
  the orphan shape this plan has now caught three times. It also declared the 300-second Lease
  coupling rather than removing it by renewing, on an argument that inverts the obvious one: renewal
  is *adversarial* to Sprint `2.47`, because a renewer outliving a wedged bring-up would hold the
  Lease live forever and restore the permanent wedge `2.47` closed. **The Lease expiring on its own is
  the mechanism, not the omission.**

**Prior head state (2026-08-14, earlier — every phase closed):**

- **Sprint `2.47` ✅ closed on a Phase `2` surface without reopening Phase `2`**, and **Sprint `2.48`
  📋 was registered but not started** on the same surface — a sprint working a `Pending Removal` row is
  not a reopen (Standard N). `2.47` closed the plan's oldest open defect: the durable
  `bootstrap-session-fence` that a preserved `.data/` carries across a teardown, which was the
  recorded blocker of the first Standard-P qualification campaign. A positively-expired predecessor
  is now retired through a CAS that already existed and the successor re-acquires, so an abandoned
  bring-up no longer wedges the host permanently.
- **The remedy had zero production callers and could not be called, and naming why is what made the
  sprint small.** `decideBootstrapFenceRetire` requires three independent facts, each refusing closed
  on ambiguity — stricter than all three options the ledger row proposed — with its store half fully
  wired. It consumed a cleanup observation bound to a seven-field worker binding, and a durable fence
  carries **three** of those seven, so a successor holding only a stale fence could never build one.
  Closed by observing worker absence **by fence generation**, checked in both directions
  ([§ 24](../documents/engineering/chaos_hardening_doctrine.md)).
- **Seven prescribed remedies were refuted by measurement across that row's life** — two the row's,
  two the sprint's own, three found while closing it. The plan's recurring lesson arrived at a new
  surface: an estimate stated in prose is not a measurement.
- **The live proof passed on the operator host**, which was already in the precondition state and
  needed no reconstruction. Five consecutive bring-ups retired fence generations 1, 2, and 3 with
  three distinct receipt digests, and runs 2 and 3 refused on their own merits — the Standard-P
  aggregate shape, not a point probe. Running it also refuted the ledger's paraphrase of the second
  blocker, killed the most attractive hypothesis about it, and surfaced a third defect nobody had
  recorded: an acquisition that CASes the fence and abandons it when the Lease step fails, which
  Sprint `2.48` went on to own and close.
- **Sprint `2.48` then found and fixed that blocker's root cause**, and the Bootstrap Broker's fence
  Lease is created for the first time: `Lease.spec.renewTime` is a `MicroTime` requiring exactly six
  fractional digits, Aeson renders `UTCTime` with a variable count, and the API server rejected the
  body `400` deterministically — so the Lease had never been creatable on any run. Proven
  server-side with four falsifiable probes and verified by a positive observation rather than an
  absent error. **The cause was named within one build of publishing the refusal's reason**, after
  two hypotheses had been refuted; that method, not the timestamp, is the transferable finding.
  Sprint `2.49` ✅ applied the same move one layer deeper against the attestation blocker the fix
  uncovered, and Sprint `2.50` ✅ closed the durable-checkpoint blocker that named itself as a
  result.
- **Two Standard-C corrections landed with it, and [Standard C](development_plan_standards.md#c-honest-completion-tracking)
  requires calling them out here as well as in [README.md](README.md).** Sprint `4.82`'s recorded
  `dev check` exit 0 did not reproduce — a Sprint-`4.76` record literal left incomplete by `4.82`'s
  new field, caught only by `dev check`'s `-Werror` build and therefore invisible to `test unit`. And
  Phase `2`'s own header still led with the 2026-08-10 reopen while every sprint in that file read
  ✅, the precise failure that header was corrected for on 2026-08-08. Evidence for this entry:
  `dev check` 0, `test unit` 0 (**3453** + 27 + 33 + 27), `test integration cli` **57/57**.

**Prior head state (2026-08-14 — Phase `4` reopens and recloses on its own surface the same day;
every other phase stays closed):**

- **Phase `4` is ✅ reclosed on Sprints `4.81` ✅ and `4.82` ✅ (Standard A own-surface reopen closed
  the same day), and the reopen is called out here because [Standard C](development_plan_standards.md#c-honest-completion-tracking)
  requires it in this document as well as in [README.md](README.md).** The trigger is a doctrine gap
  rather than a failure. [chaos_hardening_doctrine.md § 24](../documents/engineering/chaos_hardening_doctrine.md)
  requires a derived value to be enforced at the layer its source object is authoritative for, and to
  name that layer; `ResidueStatus` is the common target of **nineteen** producers — reading the
  Pulumi checkpoint store, AWS resource presence, AWS IAM, AWS EBS, config text, a Pulsar topic, a
  Vault gate, an object-store listing, SES consumer quiescence, and public-edge TLS — and has no
  field in which to name one. The producer count is a signature grep; the layer list is enumerated
  rather than counted, because bucketing them into a numeral is a judgement and would be a restated
  inventory.
  [Standard L](development_plan_standards.md#l-cli-doctrine-alignment) makes scheduling it mandatory:
  a doctrine gap may not be closed silently without a sprint block.
- **No later phase is blocked by this and no earlier phase is reopened by it** (Standard N). Phases
  `5`–`8` compose Phase `4` deliverables and stay closed and independently validatable; the reopen
  expands only the residue-observation and destructive-cleanup surfaces Phase `4` already owns
  through Sprints `4.16`, `4.19`, `4.21`, `4.76`, and `4.78`.
- **`4.81` ✅** made the layer sayable and its minting restricted — as a **field with a class-A
  opaque minter and a mutation-proven `dev check` boundary, not a type index**, because § 21 names
  *residue* explicitly in its prohibition on indexing an observed value. **`4.82` ✅** made the
  cascade consume the layer it actually needs, using the admin credential the same command already
  loads for its postflight sweep, and stopped one unobservable cause being narrated as two peer phase
  failures. Both move Standard-P destructive-cleanup surfaces; both substrate qualification rows stay
  `pending`, and `4.82`'s live proof stays 🧪 Standard-O pending without gating closure. Evidence:
  `dev check` 0, `test unit` 0 (**3444** + 27 + 33 + 27), `test integration cli` **57/57**.
- **Sprint `2.47` 🔄 registered and part-landed on a Phase `2` surface without reopening Phase `2`**
  — registering an owner for a `Pending Removal` row is not a reopen (Standard N). It closed later
  the same day; see the current head state above.

**Prior head state (2026-08-13, third entry — Phase `3` reopens and recloses on Sprints `3.36`
and `3.37`; every phase stays closed):**

- **Both sprints were found by the first live Standard-P qualification run**, which is the first time
  the plan has gained work from running the system rather than reading it. `prodbox test all
  --substrate home-local` failed deterministically, twice, at the cert-manager mirror.
- **Sprint `3.36`**: the mirror publication path passed no platform to `docker pull`/`docker push`,
  so it published the whole manifest index. Invisible until now because **every mirror target that
  had published before it presents a single platform** (17 of 24 entries). The custom-image build path beside it had always pinned the host
  architecture; the mirror path, named for it, never did. The sprint first recorded **no successful-publish
  proof** — the working mirrors were skipped — and the gap closed on the next run: seven publications,
  zero failures, across **both** of its callers.
- **Sprint `3.37`**: five hypotheses tested and discarded before a pin moved — stale cache,
  multi-arch in general, quay.io, cert-manager, controller-only. The conclusion is that the pinned
  `v1.16.2` release is unpublishable upstream while its neighbours are fine. The pin moves to
  `v1.17.1`, which **invalidates any prior component-image identity**.
- **One unowned residual recorded**: cert-manager is the only mirrored platform component with no
  fallback source, and `3.37` is the proof that this matters.

**Previous head state (2026-08-13, second entry — Phase `1` reopens and recloses on Sprint `1.89`;
every phase stays closed):**

- **Sprint `1.89` ✅ closes the ledger's last unowned row** by giving the Tier-0 coordinates a
  retained parse: `ValidatedCoordinates` on `ValidatedSettings`, built by `validateConfig` from nine
  smart-constructed types in the new `Prodbox.Settings.Coordinate`. The Dhall wire format is
  **byte-identical** — no field retyped, no schema alternative added — so no Standard-P
  generated-config identity change occurs. Counts, derived from the table:
  pending **63 → 64**, unowned **1 → 2**, completed **289 → 290**. The unowned count rising as the
  last unowned row closes is stated as the net increase it is, because the available alternative
  framing is true of the row and false of the count.
- **The row described one defect and there are two.** Nine coordinates were *decided and discarded*;
  five were **never decided at all**. Two of those five matter: `route53.zone_id` — the zone every
  home DNS write uses — was checked only for emptiness while the structurally identical
  `aws_substrate.hosted_zone_id` had been shape-checked on every load since Sprint `1.81`; and
  `pulumi_state_backend.region` had no rule anywhere while both its siblings in the same three-field
  section had one, and it is read straight into an S3 client.
- **Two drafts were refused by the repository itself, and both refusals are worth more than the
  fix.** The ACME account modelled as both-or-neither refuses `prodbox config generate`'s own output,
  because `defaultConfigFile` ships the ZeroSSL directory with an empty contact; the halves are not
  symmetric. And the new `dev check` rule's first run flagged a *correct* read, because one module
  bound `config` to both a validated and an unvalidated config — fixed by renaming the binding, not
  by weakening the rule.

**Previous head state (2026-08-13 — Phases `1`–`5` reopen and reclose; every phase stays closed):**

- **Sprints `1.87` ✅, `1.88` ✅, `2.45` ✅, `3.35` ✅, `4.78` ✅, `4.79` ✅, `4.80` ✅, and `5.34` ✅
  work the `Pending Removal` ledger** in phase-numerical order as own-surface reopens, and
  **the unowned count reaches 1**: pending **71 → 63**, unowned **9 → 1**, completed **280 → 289**.
  The survivor is the per-field Tier-0 narrowing remainder Sprint `1.88` split off, kept open
  deliberately: retyping those fields in Dhall is a Standard-P generated-config identity change.
- **Three sprints found their row's prescribed remedy unavailable or wrong.** `2.45`'s row listed
  eleven surfaces of which six already had real predicates, and missed the seventh undefended one.
  `4.78`'s worked example was measured **unreachable**, which is what made deleting three arms on a
  fail-closed teardown gate behaviour-preserving. `5.34`'s prescribed symmetric credential check is
  **not available at all**: it refuses this repository's own integration fixtures, which cannot carry
  a valid AWS key shape because Sprint `1.75`'s credential scanner fails the build for any tracked
  file that does. Two repository rules in direct opposition; the scanner wins.
- **Two rows were closed by argument rather than by code, and say so.** `4.80` answered a policy
  question with machinery the cascade already had, adding no requirement; `5.34` established that
  an all-empty `TestSecrets` fixture cannot be refused at decode, because it *is* the generated
  schema's own `default`. `1.87` closes the re-scoped successor Sprint `1.84` registered against
  itself; `1.88` **splits** the Tier-0 narrowed-types row, closing its type-guarantee half in place.
  `2.45` closed the Bootstrap-Broker durable-validity row.

- **A value with no owner cannot be drifted from, and the module that declined to own it was wrong
  about it.** The control-plane listen port was a literal in 14 places across 9 modules while
  `ChartStatics.hs` called it operator-chosen deployment configuration — and the binder hardcoded it,
  so the declared choice did not exist. The row's open question is answered by measurement: a
  per-role port is not representable in `runControlPlaneServer`, so the five per-role constants could
  never have diverged. The URL *shape* around the port was restated just as often and now derives
  from one encoder too.
- **A refusal constructor that could not be produced.** `validValue _ = True` was the validity
  predicate on every durable Bootstrap-Broker read and CAS, so `BootstrapStoreCorrupt` was
  unreachable for the payloads passing through it. The row listed eleven surfaces and called them
  "nine payload types"; six already had real predicates and it **missed** the seventh undefended one
  — the storage-generation binding every other payload is checked against. Measured: 7 types, 20
  sites. The fix is one rule: these records are read back through CBOR, which bypasses every smart
  constructor they are otherwise built through, so each predicate re-runs exactly those.
- **`ValidatedSettings` now has one production constructor.** Its row read as though the exported
  constructor were a diffuse risk across the tree; there were exactly **three** applications
  tree-wide. The one production forge built a record no validation had produced so it could call a
  function reading two of its four fields, and got its plan by `error`-ing — **deleted rather than
  guarded** by narrowing the reader, taking two production `error` calls with it. A `dev check` rule
  keys on field *assignment*, so a record update is caught too. The bound is stated as what it is: a
  compiled rule over a source region, not a property of the type. All three of the row's counts were
  restatements and all three were wrong (30/40/74 recorded, 27/18/56 measured).
- **The empty served hostname is now unconstructible rather than refused.** The row prescribed
  handing the pure renderer a resolved `String`, which leaves `""` a well-typed inhabitant and the
  refusal in caller discipline — the property `1.84` already had and recorded as insufficient. The
  renderers take the `ValidatedServedHost` that `validateConfig` already builds, whose `Fqdn` is
  minted only by `mkFqdn`; `substratePublicFqdn` is **deleted**. The stronger shape cost nothing —
  the accessor's whole body was `maybe "" servedHostString` over that same value.
- **The row's premise was wrong, and that is the finding.** It called the sites "pure renderers
  reached from IO callers": true of the renderers, false of the frames calling them. All 16 sites
  resolve at **eight** points that already held a `failWith` or a `Left`, and nine functions stopped
  taking `ValidatedSettings`/`Substrate` entirely because they carried the config only to re-derive a
  host their caller had resolved.
- **The pending total is corrected by derivation.** The 2026-08-12 entry recorded `73 → 66`; counted
  from the table the figure was `78 → 71`. The unowned and completed counts in that entry are exact;
  only the total was wrong, by five — the same *inventory stated in prose* class that pass named
  three times in one day. The derivation now sits beside the count in the ledger.

**Previous head state (2026-08-12 — Phase `0` reopens and recloses; every phase stays closed):**

- **Sprints `0.27` ✅, `0.28` ✅, `0.29` ✅, `1.84` ✅, `1.85` ✅, `1.86` ✅, and `2.44` ✅ work the
  `Pending Removal` ledger**, the plan's own stated next axis, in phase-numerical order as
  own-surface reopens. Unowned count **16 → 9**, pending ~~**73 → 66**~~ **78 → 71** (corrected
  2026-08-13 by derivation); eight rows closed and one re-scoped successor added.
- **Two rows had the wrong remedy written into them**, and measuring the caller showed it both
  times: `1.86`'s `Raw*` DTO cascades into two generically-derived records, and `2.44`'s
  "make it fail" would abort every suite run before the gate that owns the verdict was reached —
  the sampler is right to continue; it was wrong to continue *silently*.
- **`1.86` declined the shape its row prescribed, after measuring it.** A `Raw*` DTO narrowed after
  decode cascades into `ProdboxParameters` and `ConfigFile`, both deriving `FromDhall` generically.
  A validating decoder reaches the same seam with no cascade and is stronger — the DTO leaves a
  window in which the unchecked value exists, and this leaves none.
- **`1.85` closed two rows whose shape is a description contradicting what it describes** — a
  Haddock implying a production role that Sprint `1.83` removed, and a `--yes` help string reading
  "Skip confirmation prompts" on four verbs with no prompt where Sprint `4.77` made the flag *be*
  the confirmation. Neither closed by deletion: the contract function is kept and made load-bearing,
  and the help text fixed without touching the parser shared with verbs that do prompt.
- **Three of the four rows were wrong about their own measurements**, and `1.84`'s was wrong in both
  directions at once: it estimated "roughly a dozen pure manifest renderers with no error channel"
  and recorded that as measured, where the truth is six direct sites, four already in `IO ExitCode`,
  only two pure — and the real ten-site cascade sits behind a different function the row folded into
  the same count. `1.84` closes the six and **unexports** the accessor so the empty-string answer
  cannot gain a new caller; deleting it would require the ten in one coupled change, which Sprints
  `4.74` and `1.83` each declined.
- **`0.29` closes a class with a field rather than a gate**, and is the pass's one Standard-P move.
  No text comparison could catch a hand edit to a Tier-0 primitive that round-trips unchanged — the
  edited file *is* the generator's output for the record it carries. Stamping a content-derived
  witness makes the file no longer self-consistent after an edit, so the **existing** Sprint-`0.24`
  comparison catches it with no second check. It changes the content of every generated
  `prodbox.dhall`, so a qualification run must bind the post-`0.29` config identity.
- **Both rows understated their own defect, in opposite directions, for one reason: each stated an
  inventory in prose instead of deriving it.** `0.27` recorded 19/39 missing Standard-H fields
  against **11/10** measured, plus a 4-sprint category it had no name for; `0.28` recorded four
  unguarded `PRODBOX_*` reads against **12** measured. Both are now derived by a registry the
  worktree must agree with.
- **The same mistake was available to this pass and was made once**: the first Standard-H
  measurement mis-classified Sprint `1.62` exactly as the original row did, because a naive match
  does not see `**Implementation** (landed):`. The gate accepts all three heading forms for that
  reason.
- **A third assertion found holding a defect in place**, after Sprint `4.76`'s `nuke` sweep and
  Sprint `5.33`'s `gateway-partition` registration: a unit case pinned
  `destructivePlanOptionsArms` to two constructors while seven dispatched outside the region.
  `unit_testing_policy.md` statement 11 now names the class.

**Prior head state (2026-08-11, second entry — Phases `4` and `5` reclose; every phase is
closed):**

- **All four sprints the 2026-08-11 audit registered are ✅ Done**, on the conditions their
  own-surface reopens existed to remove. Phase `4` recloses on `4.76`/`4.77`; Phase `5` on
  `5.32`/`5.33`. The unowned `Pending Removal` count moves **14 → 16** while the pending total falls
  **79 → 73**: every row closed had an owner, and both rows added are unowned residuals declined
  with a stated reason.
- **A gate can hold a defect in place as firmly as it can catch one, and that is the finding to
  carry forward.** A unit case listed `discoverClusterTaggedAwsResources` among tokens forbidden in
  `src/Prodbox/CLI/Nuke.hs`, so the absence of the terminal tag sweep that
  [lifecycle_reconciliation_doctrine.md](../documents/engineering/lifecycle_reconciliation_doctrine.md)
  § 5 and § 6b have always assigned to `nuke` was an **asserted invariant**. It was found by reading
  the doctrine against the gate, not by reading the code.
- **The reported narration defect was the smallest of four that composed.** Beneath it,
  `inferCascadeSubstrate` read an unreadable backend as the home substrate — the branch where a
  skipped drain is success; `clusterReachable :: IO Bool` made a refused credential
  indistinguishable from a departed cluster; and the sweep returned `IO ()`. Each is now three-valued
  with the **uncertain arm as the default** rather than as a recognised special case, which is the
  producer-layer correction [chaos_hardening_doctrine.md § 23](../documents/engineering/chaos_hardening_doctrine.md)
  calls for.
- **The qualification machinery was the serious half, and it is now falsifiable.** The
  `LCPC-2026-07-11` reproducer consumes a repository-owned frozen trace whose dispositions are
  digest-bound, and a committed mutation fixture makes the command exit non-zero. Both Deployment
  Qualification rows were already `pending`, so **nothing is retracted** — the standing prohibition
  lifts instead: the Counterexample column may now be filled by a qualification run, where before it
  could not be filled by anything. Sprints `5.19` and `8.12`'s Standard-C corrections are updated to
  say the dependency is discharged.
- **Four sprints move Standard-P surfaces**: `4.76` and `4.77` touch destructive cleanup and
  lifecycle orchestration; `5.32` and `5.33` change which qualification inputs can fail, and `5.33`
  changes the canonical suite's node set by moving `gateway-partition` to the unit suite. All rows
  are already `pending`, so nothing is invalidated, but a future qualification run must exercise the
  post-`4.77` cascade and must not carry forward a cleanup result recorded when the sweep could not
  fail.
- **A pre-existing regression was found while validating and fixed here.** `prodbox test integration
  cli` was failing 8 of 55 before this work began — Sprint `3.34` made `endpoints/kubernetes` a live
  observation and closed without running the integration suite, and neither fake `kubectl` served
  it. The failing set was identical before and after the `4.76` code, so no sprint here caused it.
- **Sprint `4.76`'s reproduction was run live.** With RKE2 installed and its API server stopped,
  `prodbox cluster delete --cascade --yes` reported per-run state as unobserved, never printed "no
  live per-run residue", exited 1 naming the unresolved phases, and still ran the drain, reaper,
  uninstall, and sweep. The same input inferred `substrate=aws` where the pre-`4.76` predicate would
  have inferred home-local and exited 0, so the composing chain is demonstrated against live state
  rather than argued.

**Prior head state (2026-08-11, first entry — Phases `4` and `5` reopen on their own surfaces):**

- **A lifecycle narration defect and three unfalsifiable validations are the same defect shape.** A
  `cluster delete --cascade --yes` run on a host with RKE2 installed but not serving narrated three
  `unreachable` per-run statuses as "no live per-run residue" and exited 0. Phase `4` reopened on
  Sprints `4.76`/`4.77`; Phase `5` on `5.32`/`5.33`. Neither reopen blocked the other or any earlier
  phase (Standard N).
- **The type layer was not the problem, which is the useful finding.** ~45 observation-shaped ADTs
  were enumerated and nearly all give their uncertain constructor its own arm. The collapses were one
  hop upstream in the **producers** — `IO Bool` probes and `String -> Bool` prose sniffers that
  decide which constructor to mint.

**Prior head state (2026-08-10, second entry — every phase is closed):**

- Sprints `4.73`–`4.75` are ✅ Done and **Phase `4` recloses**, ending the 2026-08-09 own-surface
  reopen on the condition it existed to remove: no `Pending Removal` row on a Phase-`4` surface is
  unowned. The unowned count moves **9 → 6** (two closed, one given an owning sprint, none created),
  and all six remaining sit on Phase-`0`, `1`, and `5` surfaces.
- **The pass's finding is a row that was wrong in the flattering direction.** Sprint `4.74`'s row
  said Vault CAS callers reported coarsely; four of them already classified and **all four were
  wrong identically**, treating every `400` as a lost race when Vault answers a version mismatch and
  a malformed request with the same status. One spent an authority-epoch retry budget on a refused
  request; another reported a write that never happened as a replay conflict.
- **One sprint moves a Standard-P surface**: `4.74` (persistence protocol — four call sites change
  which outcomes count as a lost race, and one changes what consumes a retry budget). Its
  qualification row was already `pending`, so no claim is withdrawn. `4.73` writes byte-identical
  records and `4.75` moves no executable behaviour.
- **One row stays open on this phase's surface and it is owned, not unowned.** The authored
  control-plane service time needs a recorded profile; `dhall/capacity/measured/` holds only
  `Schema.dhall`, so no profile exists for any lane and this one is downstream of Sprint `5.21`'s
  recorder. Standard-O, non-blocking.
- Evidence: `prodbox dev check`, `dev docs check`, and `dev lint docs` exit 0; `prodbox test unit`
  exit 0 at main Hspec **3294/3294** plus 27/27, 33/33, 27/27; installed
  `prodbox test integration cli` **55/55**, exit 0.
- Clean-room deployment qualification remains `pending` on both substrates as the separate
  Standards O/P axis, with no deployment-ready or cutover claim.

**Prior head state (2026-08-10 — every phase but `4` is closed; Phase `4` is 🔄 Active on one
unowned ledger row):**

- Sprints `4.67`–`4.72` are ✅ Done. They close five of the six unowned `Pending Removal` rows Phase
  `4` owned; the unowned count moves **12 → 9** (five closed, one narrowed and replaced, three new
  residuals registered rather than absorbed).
- **The pass's recurring finding is a mechanism that was enforcing nothing.** The bounded admission
  machine Sprint `4.68` wires in has existed since Sprint `1.62` with no production consumer on the
  accept path, and Sprint `4.72` measured that `DnsRecordProgram` appeared **only in two unit
  suites** before it — so the typed DNS program bounded no running code. Both are the shape Sprint
  `1.82` closed for the Tier-0 secret guard.
- **Two sprints move Standard-P surfaces**: `4.68` (queueing/admission and absolute-deadline
  composition — in-process concurrency goes from unbounded to a compiled four) and `4.71`
  (persistence protocol — four Vault writes that always succeeded can now be refused, and one is
  create-only). Both qualification rows were already `pending`, so no claim is withdrawn.
- **Phase `4` stays Active on the SES DNS writer**, narrowed with a measured reason: three record
  types against two defined, five records in one batched change with a single propagation wait, and
  desired values that may require creating the SES identity before the records are known. That is a
  redesign of the SES DNS mutation rather than a rerouting of it.
- Evidence: `prodbox dev check`, `dev docs check`, and `dev lint docs` exit 0; `prodbox test unit`
  exit 0 at main Hspec **3287/3287** plus 27/27, 33/33, 27/27; installed
  `prodbox test integration cli` **55/55**, exit 0.
- Clean-room deployment qualification remains `pending` on both substrates as the separate
  Standards O/P axis, with no deployment-ready or cutover claim.

**Prior head state (2026-08-09 — all code-owned phases are closed):**

- Sprint `5.31` is ✅ Done and Phase `5` is reclosed on its own surface. Installed `cli` and `env`
  integration pass **55/55**; canonical `prodbox test unit` exits 0 with main Hspec **3255/3255**.
- The last four failures were fixture drift: the fake cluster observed three gateway Pods against
  the typed exact projection of two; the transient primary image push retries and succeeds without
  selecting the fallback; config setup is asserted through the derived Dhall union constructor and
  structural decode; and a valid fixture AWS subzone lets the AWS-IAM teardown fixture reach its
  already-specified unavailable-Credential-Provisioner refusal.
- Every code-owned phase `0`–`8` is closed. Clean-room deployment qualification remains `pending`
  on both substrates as the separate Standards O/P axis, with no deployment-ready or cutover claim.

**Prior head state (2026-08-03 — all code-owned phases are closed):**

- Sprints `0.19`/`0.20` add repository secret hygiene and then repository value hygiene as governance
  additions on Phase `0`'s already-reclosed documentation surface (no further reclose event).
  `vault_doctrine.md` §20 requires every committed value that stands in for real-world data to be
  officially synthetic, unmistakably synthetic, or genuinely real and declared as such in place.
- Phases `1`, `3`, `5`, and `7` reopen on their **own** surfaces (Standard A/N) to land the remediation
  each owns — Sprint `1.74` declares two real non-secret constants in production source, Sprint
  `3.30` declares the RFC 6455 handshake GUID and repoints the MinIO chart credential comment, Sprint
  `5.26` replaces fixture values that imitated real-world data, and Sprint `7.35` redacts two real
  per-run cloud resource ids from that phase's own live-run narrative and declares its Pulumi
  programs' real values. No later phase reopened any of them; each is validated on its owned surface.
- The numerical completion pass validated and closed every sprint through `8.12` in order.
- Sprint `8.12` is the final code-owned closure: its typed artifact fixes eight invite assertions,
  23 exhaustive fault dispositions, both substrate commands, Authority epoch and exact backup
  restoration, cleanup takeover, and retained SES/EAB/TLS constraints.
- Deployment qualification remains pending for the two live current-revision substrate campaigns.
  This is a non-blocking Standards O/P axis and the repository makes no deployment-ready,
  seamless, or operational-cutover claim.

Prior head state (2026-07-27 — Phase `2` reclosed on proof-carrying broker shutdown; redesign
continues):

- Sprint `2.36` closes the Bootstrap Broker forced-shutdown counterexample: replay waiters resolve
  before persistent cancellation children join, and only an exact-empty witness publishes
  `Stopped`.
- Sprint `5.23` is ✅ Done on its code-owned surface: `Prodbox.Bootstrap.Broker.ShutdownModel` is a
  pure, exhaustively-scheduled abstraction of the forced-drain shutdown that proves the pre-fix
  `Stopped + live replay waiter` counterexample reachable and unreachable under Sprint 2.36's
  proof-carrying postcondition, with a run-final residue oracle over queued connections, unfinalized
  workers, and live replay-waiter cells. Wiring that oracle into the live canonical-suite fixture
  teardown is the non-blocking Standard-O axis.

The current revision is not deployment-qualified. The aggregate suite demonstrated that nominal
readiness could pass or eventually return while the gateway's shared CPU/child lane could not meet
the client deadline, that the AWS precondition and retained home authority were different failure
domains, that continuity workers could interleave one logical transition, and that a retained SES
failure could skip independent local restoration.

The target correction is physical and type-directed: Bootstrap Broker, Lifecycle Authority, Target
Secret Agent, and Gateway Runtime are separate workloads; operation-indexed `CapabilityRef`s bind
observation/admission/execution; the authority uses a durable decide/evolve journal and outbox;
gateway emitters use single-writer identity-bound journals; one absolute deadline spans each call;
and cleanup is an always-run DAG.

Sprint `2.32` has completed that emitter target on its independently validated code surface. The
target and rollback topologies are mutually exclusive, and the production entrypoint remains
`LegacyModelBEmitter` until current-revision deployment qualification permits cutover.

Sprint `0.16` owns this doctrine/plan correction. Phases `1`–`8` have reclosed on their expanded
code-owned surfaces. Earlier completed sprints remain historical evidence for their stated
surfaces, not evidence that the current topology is qualified. Deployment qualification status
and evidence live only in
[DEVELOPMENT_PLAN/README.md](README.md#deployment-qualification).

**Foundation Epoch (2026-07-12 — adopted by Sprint `0.17`):**

Counterexample `LCPC-2026-07-11` froze four aggregate-suite failure mechanisms: an uncertified
zero-headroom gateway CPU envelope, four divergent readiness notions across the daemon, lifecycle
gate, client, and chart-probe surfaces, chart-lifetime custody of the retained SES authority's CAS
objects together with a postflight residue policy able to destroy the retained stack, and a
fail-fast restore fold that silently discards independent restorations. The corrective doctrine is
"one typed model, many generated projections": cross-artifact contracts are single-sourced in
compiled values and generated outward, coverage is derived by total folds over closed registries,
resource envelopes are certified against measured profiles, over-commitment of the
host/cluster/workload nesting is made unrepresentable by an opaque compile-time proof (Sprint `1.68`),
and drift fails the seconds-fast
canonical quality gate rather than the multi-hour aggregate suite. Foundation Epoch Sprints
`1.63`–`1.66`, `2.34`, `4.51`, `5.20`, `5.21`, and `7.34` are Done. Sprints `1.61`/`1.62` are also Done after their shrink-rescoped work landed
(readiness evidence moved to Sprint `2.34`; the cached Vault session to Sprint `1.64`; the native
S3 client to Sprint `1.66`). Standard P gains the interim
escape-path guard (registry owned by Sprint `1.63`), Guaranteed QoS is retained with honesty coming
from measured-profile certification, and the harness postflight residue bypass narrows back to
per-run under Sprint `7.34`, reversing part of Sprint `7.9`. The Deployment Qualification ledger is
unchanged — both rows remain pending; nothing in the epoch adoption claims qualification. Governance
Sprint `0.18` (2026-07-12) adopts the operator-configurable certificate-scope policy on the same
documentation surface: an unmanaged or uncovered served hostname is unrepresentable on the
prodbox-managed side, the orphan dashboard-cert incident is dispositioned, and parent→child
certificate-material handoff is rejected in favor of delivered `AcmeEabMaterial` self-issuance.
Sprint `2.35` and its independent serving consumer Sprint `5.22` are now Done;
Phase `0` retains the governance addition without a second reclose, and the Deployment Qualification
ledger is unchanged. The dated adoption entry lives in
[README.md → Historical Closure Record](README.md#historical-closure-record); current status lives
only in [README.md → Resume Here](README.md#resume-here).

## Architecture Summary

| Surface | Canonical Target Path | Authority |
|---------|-----------------------|-----------|
| CLI control plane | `prodbox <command>` | Haskell executable |
| Host build artifacts | `.build/prodbox` | `cabal build --builddir=.build exe:prodbox` plus copy to `.build/prodbox` |
| Container build artifacts | `/opt/build` via Dockerfiles under `docker/` | Repository-owned Dockerfiles |
| Supported host runtime | `Ubuntu 24.04 LTS` with systemd | `prodbox` supported-host gate |
| Configuration | Binary-sibling Tier-0 `prodbox.dhall` decoded directly into Haskell types through its `parameters` payload, with generated `prodbox-config-types.dhall` / `test-secrets-types.dhall` schemas and no supported `prodbox-config.json` artifact | Executable sibling plus Haskell schema renderer |
| Host diagnostics | `prodbox host ensure-tools|check-ports|info|firewall ...` | Haskell CLI |
| Local RKE2 lifecycle | `prodbox cluster reconcile|delete --yes|delete --cascade|status|health|wait|start|stop|restart|logs|workload-logs` | Local-only delete preserves `.data` and makes no AWS claim. Target cascade starts/resumes the lifecycle-owned recover-to-clean graph and uninstalls only from `ReadyToUninstallEvidence`; incomplete results report `RecoveryPlaneDisposition`, and completion additionally requires exact host absence plus a read-back local receipt. |
| Registry and image reconcile | Single-binary in-cluster `registry:2` with MinIO storage, a bounded storage-bootstrap exception, idempotent public/custom-image population, alternate-source retry, and native-host-architecture publication for the Envoy Gateway edge and chart workloads | Haskell lifecycle runtime |
| Kubernetes utilities | `prodbox cluster health|wait|logs|workload-logs` | Haskell CLI |
| AWS substrate provision/teardown (EKS) | `prodbox aws stack eks reconcile|destroy --yes` | Current Haskell orchestration plus Pulumi surface; Sprint `7.36` supplies the exact independent lifecycle adapter consumed by the qualification-gated cutover. |
| AWS substrate desired absence target (EKS) | Exact independent `aws-eks` observer, write-ahead ownership manifest, bounded controller families, provider-issued expiring drain session, checkpoint/backup recovery, and mandatory exact absence read-back | Implemented Phase 7 adapter interpreted through the Phase 4 lifecycle kernel; global tag audit cannot select this target. |
| AWS substrate provision/teardown (Route 53 subzone) | `prodbox aws stack aws-subzone reconcile|destroy --yes` | Haskell orchestration plus Pulumi; provisions the delegated AWS-substrate hosted zone used by public-edge proofs. |
| AWS substrate provision/teardown (HA RKE2) | `prodbox aws stack test reconcile|destroy --yes` | Haskell orchestration plus Pulumi; provisions the EC2 portion of the AWS substrate. The `ha-rke2-aws` canonical suite validation runs against it. |
| Pulumi backend state | Immutable encrypted checkpoint blobs: primary bytes in MinIO `prodbox-state` plus mandatory receipt-committed exact copies at the independent long-lived S3 coordinate, referenced atomically from a versioned Lifecycle Authority record and hydrated only into bounded RAM-backed scratch | Lifecycle Authority plus separate Backup Adapter and fenced provider worker; gateway and host-direct transports have no post-cutover authority |
| Per-run Pulumi state (MinIO-backed; survives cluster wipes via MinIO's PV under `.data/prodbox/minio/0`) | Opaque `objects/<id>.enc` Model-B objects produced by `Prodbox.Pulumi.EncryptedBackend`; first-touch raw checkpoint migration imports legacy backend state before supported writes continue encrypted | Haskell Pulumi orchestration and AWS substrate helpers |
| Gateway-owned secret-derivation MinIO bucket — **retired** | Historical `s3://prodbox?endpoint=127.0.0.1:39000` / `prodbox/master-seed`; the master-seed derivation model is retired (Sprint `3.19`). The pre-cutover gateway generic-object route is also scheduled for deletion; the target Gateway has no MinIO principal. | No target authority; history is retained only in the cleanup ledger |
| Bootstrap Broker | Same-binary dedicated pre-Vault daemon command and internal Service | Sole bounded Vault initialize/unseal/status/rotation boundary; no mesh, lifecycle, provider, or target-secret API |
| Lifecycle Authority | Same-binary retained control-plane daemon and internal Service | Authority epoch/time, operation journal, fences, checkpoint references, provider revisions, credential generations, and delivery outbox |
| Ordinary teardown recovery profile | Minimal RKE2/API, retained MinIO/Vault bindings, Broker unseal path, bootstrap-core external caller identity, Lifecycle Authority, Backup Adapter, Provider Worker, and conditionally required Target Agent | Derived capability closure; excludes Gateway/apps and resumes old cleanup before new admission. An incomplete result distinguishes established, never-established, and subsequently lost recovery planes. |
| Target Secret Agent | Same-binary per-substrate internal daemon and Service | Allowlisted generation-checked Vault KV seal/CAS/read-back for that substrate plus an exact Kubernetes TLS-Secret lane. The retained home Agent also binds the two schema-closed SES-SMTP/ACME-EAB custody rewrap endpoints; selected one-shot workers receive only destination-sealed openings. |
| Authority Backup Adapter | Separate retained-home private Deployment and ServiceAccount | Closed mandatory independent-S3 backup/read-back/restore/GC programs; sole reader of the backup-store generation |
| TLS Retention Adapter | Separate retained-home private Deployment and ServiceAccount | Closed ciphertext-only public-edge TLS retain/read-back/restore-receipt programs; never sees certificate/key plaintext |
| Fenced Provider Worker | Separate retained-home private Deployment and ServiceAccount | Normal committed Pulumi/AWS provider intents only; sole reader of the Lifecycle-provider generation. Its SES inventory is sending identity/DKIM/MX/rules/capture only and has no IAM credential constructor. |
| Credential Provisioner | On-demand ephemeral attested Job | One active mode-indexed genesis-backup, backup-repair, or operator-material permit at a time plus authenticated AWS-admin prompt ingress and direct Target-Agent handoff. The bounded first-reconcile session may process only the receipt-ordered identity members of its Genesis-bound plan digest and is absent after the session; every later action uses a fresh Job/prompt. It owns SES-SMTP create/rotate/remint, repair-time key deletion, and in-memory region-bound SMTP derivation, but not explicit `DestroyAwsSes`. |
| External Material Ingress | On-demand ephemeral attested Job | Exactly one schema-indexed non-AWS material permit, initially ACME EAB; direct closed-payload handoff to retained-home Agent custody. It cannot reuse the AWS-admin session/identity plan, expose arbitrary paths/bytes, or make `config setup` secret-bearing. |
| Admin Action Runner | On-demand ephemeral attested Job | Exactly one backup-receipted `DestroyAwsSes`, backend migrate/compatibility, or quota request/status permit. `DestroyAwsSes` proves consumers quiescent, waits for the Provider Worker's provider-stack absence receipt, deletes/read-backs external SMTP IAM, then tombstones target/custody Vault state while Agents live; all failures aggregate. Its action-indexed interpreter is not a normal provider-intent or credential capability. |
| Decommission Runner | Standalone post-export process | Verifies and executes only a signed external decommission manifest after Authority permanent stop |
| Gateway runtime operations | `prodbox gateway start --config <path>|status --config <path>|config-gen <output-path> --node-id <node-id>` | Haskell gateway mesh/DNS runtime with one actor and encrypted identity-bound retained journal per emitter; no lifecycle/bootstrap/object-store/target-secret proxy |
| Public workload runtime | `prodbox workload start --config <path>` | Haskell runtime selected only through the `workload.mode = Api \| Websocket` field of the mounted Dhall config per [config_doctrine.md](../documents/engineering/config_doctrine.md); Sprint `3.14` removed the legacy env-var selector |
| Public A-record writes | Home `CapabilityRef 'GatewayDnsReconcileReadBack`; AWS registered Lifecycle Authority provider intent | Home Gateway-DNS owns only the exact home record. EKS Gateway DNS is disabled; the AWS A record points at Envoy NLB targets and is observed/ensured/deleted/read back by the retained authority's narrow AWS-edge worker. |
| DNS check | `prodbox dns check` | Haskell CLI |
| Shared public-edge route catalog | `src/Prodbox/PublicEdge.hs` | Haskell-owned shared-host path catalog and issuer derivation for application and admin routes |
| Chart delivery | `prodbox charts list|status <chart>|reconcile <chart> [--dry-run] [--plan-file <path>]|delete <chart> [--yes] [--dry-run] [--plan-file <path>]` | Haskell chart platform over the supported `gateway`, `keycloak`, `vscode`, `api`, and `websocket` chart surfaces, with `gateway` kept separate from the Envoy public edge and the shared-host browser, API, WebSocket, and admin paths delivered behind Envoy |
| Public-edge diagnostics | `prodbox edge status` | Haskell CLI on a single-host Gateway API and Envoy Gateway doctrine, including path-route classification for app and admin surfaces |
| Public-edge auth model | Envoy-enforced Keycloak JWT auth and RBAC on the shared hostname, with explicit bearer-token carriers, browser return paths, and JWKS metadata ownership | Keycloak issuer plus Envoy policy |
| Public-edge transport boundary | Public listener TLS terminates at Envoy on the supported path; backend HTTP remains the current workload default and backend TLS or mTLS requires later explicit doctrine ownership | Haskell lifecycle plus chart doctrine |
| Optional realtime-state model | Redis-backed shared state for supported WebSocket workloads today and any later explicit external rate-limit service | Haskell chart platform plus application workload doctrine |
| Interactive onboarding | `prodbox config setup` | Haskell CLI authors and validates Tier-0 boot/proposal coordinates only; credentialed effects use their explicit command and permit path |
| AWS IAM, quota, and EBS maintenance | `prodbox aws policy|setup|teardown|quotas check|quotas request|ebs reap-test --yes` | The public names remain Haskell CLI surfaces. Identity setup/rotation/repair uses a mode-indexed Credential Provisioner; it is the sole SES-SMTP create/rotate/remint and repair-key-delete owner and derives the SMTP payload before handing only `SesSmtpSource` to home custody. `DestroyAwsSes`/migrate/compatibility/quota actions use the separate Admin Action Runner; normal EBS/provider work uses the fenced Provider Worker, whose SES program cannot represent IAM credentials. Teardown follows lifecycle-class-correct dependency cleanup; `nuke` runs only from an externally exported manifest and retires TLS prefixes before the final shared backup-store/bucket node. |
| AWS IAM validation harness | `prodbox test integration aws-iam`, targeted `prodbox test integration <name> --substrate aws` validations, `prodbox test integration all`, `prodbox test all` | The harness submits the same role-specific durable setup operation as the public flow and registers cleanup before mutation. It deletes/re-observes and tombstones only Operational Lifecycle-provider/AWS-run DNS01 resources after dependants; it exact-consumer-read-backs retained backup/TLS/home-DNS/SES-SMTP generations and custody receipts. The current one-user/shared-`aws.*` and Pulumi-owned SMTP implementations are pre-cutover history owned by Sprints `4.50`/`7.33`/`8.11`, not this target row. |
| Leak-proof resource lifecycle | Target `Prodbox.Lifecycle.Teardown.*` plus lifecycle-owned `CleanupRun` | Pure lifecycle-indexed registry; separate exact resource/checkpoint/audit observations; ARN-normalized inventory; total desired-absence decisions; closed result-indexed programs; durable derived graph; private proof-carrying completion. Validation and CLI are clients. |
| Formal verification | `prodbox dev tla-check` | Haskell CLI invoking the TLA+ toolchain |
| Code quality gate | `prodbox dev check` | Haskell CLI plus governed doctrine-alignment enforcement |
| Status and blockers | `DEVELOPMENT_PLAN/` | This plan suite |

## Implemented Baseline Reference

The Haskell-only baseline remains the pre-cutover implementation reference. Its cascade carries the
unkeyed global AWS fallback, tag-row cardinality,
checkpoint-coupled EKS access, Gateway-owned caller identity, handwritten phase/executor shapes,
and uninstall-on-incomplete behavior registered for deletion. Those paths are the measured
superseded baseline, not the target architecture.

The current target and execution status live only in
[README.md → Resume Here](README.md#resume-here). Both substrate qualification rows are pending. The
supported operator surface remains `prodbox`; configuration remains direct `Dhall -> Haskell
types`; and Python runtime/tooling remains absent.

Sprints `1.60`, `2.31`, `3.25`, `4.47`, `5.16`, `5.17`, and `8.10` remain complete historical work
for their stated surfaces. They do not qualify the expanded process topology. The supported
operator surface remains `prodbox`; configuration remains direct `Dhall -> Haskell types` rooted at
the binary-sibling Tier-0 `prodbox.dhall`; test-only plaintext remains isolated to
`test-secrets.dhall`; build roots remain `.build/prodbox` and `/opt/build`; and unsupported Python
runtime/tooling surfaces remain removed.
The supported public edge uses MetalLB, Envoy Gateway, Gateway API, cert-manager, and
Keycloak on the substrate's single validated served FQDN. Every externally reachable
application or operational dashboard routes through explicit shared-host paths such as `/auth`,
`/vscode`, `/api`, `/ws`, and `/minio`, protected by Keycloak-backed JWT auth or RBAC
at Envoy, with one Route 53 record and one listener certificate. The shipped API route validates
bearer tokens locally at Envoy from Keycloak issuer metadata plus JWKS-backed signing keys,
browser-auth and direct-OIDC flows stay explicit on their owned paths, WebSocket workloads close
on a true `/ws` upgrade with Redis-backed shared state and readiness-based drain, and public TLS
terminates at Envoy while backend TLS or mTLS remains outside the supported chart-workload
contract.

Root guidance and governed doctrine agree on the target Bootstrap Broker, Lifecycle Authority,
Target Secret Agent, and Gateway Runtime split. Current implementation and qualification status
remain plan-owned rather than duplicated in engineering docs.

The lifecycle target defined by the engineering doctrine uses a single in-cluster `registry:2`
with MinIO storage and
native-architecture-only publication: every later Helm deployment pulls through that registry,
and `amd64` or `arm64` hosts build and publish only their own architecture. The stack
closes on in-image `ghcup` with pinned GHC `9.12.4` in the single union runtime Dockerfile, the
Percona operator-backed Patroni PostgreSQL doctrine, and config-selected MetalLB L2 or BGP
advertisement. The cleanup ledger preserves completed history and, after the May 23, 2026
reopen of Phases `2`, `3`, and `4`, carries the cluster-as-source-of-truth and
native-HTTP-client removal rows owned by Sprints `2.17`, `3.13`, `4.16`, and `4.18`. The
separate Haskell distributed gateway daemon remains distinct from the Envoy Gateway public
edge.

The canonical validation contract for this worktree is the `prodbox` command surface documented
below; environment-dependent AWS and public-edge proof remain attached to those commands rather
than restated here as a fresh rerun log.

### Supported Haskell Surface

- The Haskell sources, Cabal definitions, and tests that build the supported `prodbox` binary and
  own the CLI frontend, lifecycle runtime, chart platform, public-workload runtime, gateway
  runtime, AWS integrations, and test harness live under `app/`, `src/Prodbox/`, `test/`,
  `prodbox.cabal`, and `cabal.project`.
- Python source, Python packaging, Python tests, Python type stubs, Python Pulumi programs, and
  Python bridge modules are removed from the repository.
- The supported config contract is direct `Dhall -> Haskell types` from the executable-sibling
  `prodbox.dhall`; `prodbox-config.json` is not materialized on the supported path.
- `src/Prodbox/BuildSupport.hs` owns the `.build/prodbox` copy step and `.build/support`
  linker-support shim, while `src/Prodbox/Repo.hs` owns repository-root discovery plus
  executable-sibling config-path resolution for the direct-Dhall command surface.
- `src/Prodbox/CheckCode.hs` now fails on repository-owned workflow or git-hook surfaces before it
  runs Fourmolu, HLint, warning-clean Cabal builds, and the operator-binary sync step, closing on
  the governed doctrine-alignment contract described by
  `documents/engineering/code_quality.md`. The repo-owned policy scan excludes generated or
  retained runtime roots such as `.build/`, `dist-newstyle/`, and `.data/`.
- `src/Prodbox/Aws.hs` owns the standalone AWS administration command family. Elevated/admin AWS
  power enters through `SecretRef.Prompt` only after a signed permit selects an attested ephemeral
  Credential Provisioner or Admin Action Runner. Prompt bytes travel only over authenticated
  process stdin, are never argv/environment/Kubernetes-object/disk/log/Authority/Provider/Gateway
  data, and are discarded after one closed action. `prodbox config setup` authors Tier-0
  coordinates and does not perform credentialed effects. Total `nuke` instead uses the distinct
  post-export Decommission Runner. The test harness automates the permitted prompt by feeding the
  `TestPlaintext` `aws_admin_for_test_simulation.*` fixture from
  `test-secrets.dhall` for suite-driven destructive validation, long-lived stack, and `prodbox nuke`
  flows.
- `src/Prodbox/TestPlan.hs`, `src/Prodbox/TestRunner.hs`, and `src/Prodbox/TestValidation.hs`
  now route `prodbox test integration aws-iam`, targeted
  `prodbox test integration <name> --substrate aws` validations,
  `prodbox test integration all`, and `prodbox test all` through one suite-level Haskell IAM
  harness.
- The target harness reconciles separate Lifecycle-provider, long-lived Authority-backup,
  TLS-retention, Gateway-DNS, per-substrate cert-manager-DNS01, and deterministic `LongLived`
  SES-SMTP IAM resources, target-seals and generation-CAS delivers every key, and proves each exact
  capability independently. The retained-home Agent keeps only closed schema-bound SES-SMTP/ACME-
  EAB custody and can rewrap the same generation to a fresh AWS Agent/Vault; Authority never sees
  plaintext. Ordinary suite cleanup revokes/tombstones only Operational identities; backup/TLS/
  home-DNS/SES-SMTP generations and custody remain with their live exact consumers. Explicit
  `DestroyAwsSes` removes external SMTP IAM before target/custody tombstones; explicit consumer
  decommission may remove TLS/home-DNS, while backup is nuke-only. The current shared-user,
  selected-target-only materialization, and Pulumi-owned SMTP implementations are pre-cutover legacy
  owned by Sprints `4.50`, `7.33`, and `8.11`.
- Phase `7` keeps `pulumi_logged_in` behind the visible local runbook on aggregate and
  cluster-backed suite paths.
- `src/Prodbox/AwsEnvironment.hs` now isolates supported AWS subprocesses from ambient host AWS
  auth and profile state before projecting Vault/Tier-0 credentials into the supported command
  paths.
- The target container topology lives entirely under `docker/`. Every Haskell-build Dockerfile is
  single-stage `ubuntu:24.04`, installs `ghcup` in-image, pins GHC `9.12.4`, and avoids
  symlinked Haskell tool shims.
- `src/Prodbox/CLI/Rke2.hs` owns the in-cluster `registry:2` lifecycle, readiness gates, registry
  population, registry-backed workload reconcile, native-host-architecture custom-image
  publication, and alternate-source retry during image publication, including
  `mirror.gcr.io` fallbacks for the Docker Hub-hosted Percona and Envoy images used by the
  supported lifecycle. The current lifecycle installs Envoy Gateway and the registry-backed Envoy
  image set for the supported public edge.
- The Helm-driven lifecycle restore now retries transient upstream chart-fetch failures before
  failing the supported path.
- `docker/prodbox.Dockerfile` (the single union runtime image) and `src/Prodbox/CLI/Rke2.hs` now
  close on the `ghcup` plus `ghc-9.12.4` toolchain path with no symlinked GHC shims and no
  mounted `haskell:9.6.7-slim` BuildKit context.
- `src/Prodbox/PostgresPlatform.hs`, `src/Prodbox/Lib/ChartPlatform.hs`, and
  `charts/keycloak-postgres/` now close on namespace-local Patroni PostgreSQL HA through the
  Percona operator while preserving the three-replica, synchronous-replication,
  retained-credential, deterministic manual-PV rebinding, retained secret rendering,
  convergence gate, retained-follower reinitialization, and no-embedded-PostgreSQL guarantees.
- `src/Prodbox/CLI/Pulumi.hs` plus the stack-local YAML Pulumi definitions under
  `pulumi/aws-eks/`, `pulumi/aws-eks-subzone/`, `pulumi/aws-test/`, and `pulumi/aws-ses/` back the
  public `prodbox aws stack ...` command surface for AWS substrate IaC, while
  `src/Prodbox/CLI/Rke2.hs` keeps bootstrap DNS reconcile and ACME `ClusterIssuer` projection on
  the lifecycle path.
- `src/Prodbox/Infra/MinioBackend.hs`, `src/Prodbox/EffectInterpreter.hs`,
  `src/Prodbox/Infra/AwsTestStack.hs`, and `src/Prodbox/Infra/AwsEksTestStack.hs` now keep the
  daemon-mediated encrypted Model-B Pulumi checkpoint store on a bounded scratch-backend path and repair a
  deleted MinIO export host-path mount by recreating the declared retained directory plus
  restarting `statefulset/minio` before backend validation continues.
- `src/Prodbox/Infra/AwsTestStack.hs`, `src/Prodbox/Infra/AwsEksTestStack.hs`, and
  `src/Prodbox/Infra/AwsEksSubzoneStack.hs` run Pulumi through
  `Prodbox.Pulumi.EncryptedBackend`, so the stack checkpoint survives cluster wipes as an
  opaque Model-B object in MinIO while Pulumi only sees a scratch `file://` backend
  (Sprint `4.16` replaces the prior `.prodbox-state/<stack>/stack-snapshot.json`
  file-existence predicate with `<stack>ResidueStatus` queries; Sprint `7.14` moves
  those queries onto encrypted checkpoint presence). The HA-RKE2 validation SSH key is fetched on
  demand from `pulumi stack output --show-secrets` into a `mktemp` file scoped to the
  validation run (Sprint `4.18`); the HA-RKE2 validation destroys and recreates the
  retained
  `aws-test` stack once when Pulumi reconcile succeeds but SSH validation fails, repairing stale
  EC2 instances left by interrupted runs or operator network moves.
- `src/Prodbox/CLI/Rke2.hs` now closes the supported lifecycle on the clean-room Envoy Gateway
  and Percona reconcile path with no retained Traefik or pre-Percona operator migration shims.
- `src/Prodbox/Infra/AwsTestStack.hs` and `src/Prodbox/Infra/AwsEksTestStack.hs` now sync only
  the supported retained AWS-validation stack inputs and no longer remove older Pulumi AWS
  provider-key layouts on the supported path.
- `src/Prodbox/PublicEdge.hs` now centralizes the single-host route catalog, canonical route
  URLs, and Keycloak issuer derivation consumed by lifecycle, DNS, chart, workload, host-
  diagnostic, and native validation surfaces.
- `src/Prodbox/Gateway/Bounds.hs`, `State.hs`, `Orders.hs`, `Peer.hs`, `Continuity.hs`,
  `ContinuityStore.hs`, `DnsAuthority.hs`, `ChildSchedule.hs`, and `Daemon.hs` own the bounded
  Haskell gateway runtime. `/v1/state` exposes finite semantic/replay counts, a fixed-capacity
  recent-assertion hash tail, bounded nested peer receive cursors, and the already-observed
  continuity disposition; it has no process-lifetime event total. Signed per-emitter deltas and
  bounded semantic checkpoint/suffix repair converge keyed latest-heartbeat/ownership state.
  Each local emitter write-ahead-stages the exact signed assertion and next anchor in its retained
  Model-B continuity record before publication; a durable Vault admission marker makes lost
  previously-admitted state fail closed. Route 53 consumes only a typed credential-, claim-, and
  continuity-authorized action under the shared capacity-one child permit. The certificate, key,
  CA, and socket metadata remain materialized at runtime; inbound heartbeat evidence is skew- and
  Orders-validated.
- `src/Prodbox/TestRunner.hs`, `src/Prodbox/TestPlan.hs`, and `src/Prodbox/TestValidation.hs`
  own the aggregate reruns, named Haskell-owned validation flows, and destructive postflight restore
  path.
- An in-cluster Vault platform component and a `prodbox vault` command group are the active
  structure for fail-closed secrets / KMS / PKI. The platform component runs Vault
  in-cluster on a durable `.data/vault/vault/0` PV alongside MinIO's PV (Sprint `3.17`
  code-owned foundation), and the `prodbox vault status` / `init` / `unseal` / `seal` / `reconcile` /
  `rotate-unlock-bundle` / `rotate-transit-key <key>` / `pki status` / `pki issue-test-cert`
  command group is on the public CLI surface (Sprint `1.36`, with the encrypted unlock bundle now
  MinIO-only under Sprint `7.25`; the base reconcile plan covers mounts, Kubernetes auth, policies,
  roles, and Transit keys, and all `vault` leaves have native handlers). Sprint
  `4.29` folds root/local Vault deploy, init-if-empty, unseal, and policy reconcile into
  `cluster reconcile` and preserves the durable Vault PV on delete; Sprint `4.32` adds the child
  Transit-seal lifecycle branch and parent-readiness fail-closed cascade. Sprint `5.8` has landed
  the code-owned `sealed-vault` named validation, pure audit helper, and live home proof, closing
  its code-owned surface; the live AWS-substrate sealed-Vault exercise is the non-blocking
  **Live-proof: pending** axis (Standard O), tracked in the [substrates.md](substrates.md) parity
  table and never a backward block on Phase `5`. The typed
  `Prodbox.Settings.SecretRef` config contract has the
  FileSecret-free union, Vault KV resolver seam, and production plaintext validator under Sprint
  `1.35`; the production Vault-Transit `DekCipher` lives in `Prodbox.Vault.TransitCipher` under
  Sprint `1.37`, and the same sprint wires the seal-status gate into real Pulumi apply/destroy
  paths via `runPulumiCommandWithGate`. See
  [vault_doctrine.md](../documents/engineering/vault_doctrine.md).

### Canonical Validation Gates

- Build and sync the operator binary through `cabal build --builddir=.build exe:prodbox` plus the
  `.build/prodbox` copy step.
- Run `prodbox dev check`.
- Run `prodbox test unit`.
- Run `prodbox test integration cli`.
- Run `prodbox test integration env`.
- Run the named Haskell-owned validation flows owned by `src/Prodbox/TestValidation.hs`.
- Run the aggregate reruns `prodbox test integration all` and `prodbox test all`.

**These gates have different regions, and the differences are load-bearing.** `prodbox dev check`
formats and lints `app src test`, and since Sprint `5.30` its type-checking build is scoped
`all --enable-tests`, which resolves to the library, the `prodbox` executable, **and the eight test
suites**. Before `5.30` it was scoped `all` alone — the library and the executable only — so a type
error in `test/` was caught by `prodbox test unit` or `prodbox test integration cli` / `env` and by
nothing else. That is how a 2026-08-07 config type change broke twenty integration cases and was
recorded as `Done`: a sprint whose Validation section named only `dev check` and `prodbox test unit`
had not exercised the integration suite, and could not have.

The widening closes the *compile* gap, not the *behaviour* gap. `dev check` now proves the test tree
type-checks; it still runs no test. A fixture that compiles against a changed type and asserts the
wrong thing is caught by the suites and by nothing else, so the commands above are still run
individually rather than inferred from the first one. The general rule is "The region of Ring 2" in
[resource_scaling_doctrine.md § 2C](../documents/engineering/resource_scaling_doctrine.md).

### Interpretation

The unaffected baseline remains Haskell-only and retains the AWS stack surface, in-cluster
`registry:2`, and Percona-backed Patroni path. The combined gateway lifecycle/config/credential
implementation in the table below is historical pre-cutover inventory, not the target authority
model. Replacement and removal ownership live in the reopened phases and
[legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md).

## Historical Implemented Baseline by Surface

| Surface | Implementation | Completed In |
|---------|----------------|--------------|
| CLI frontend and command surface | `app/prodbox/Main.hs`, `src/Prodbox/CLI/Command.hs`, `src/Prodbox/CLI/Parser.hs`, `src/Prodbox/Native.hs` | Phase 1 |
| Configuration and settings | `src/Prodbox/Settings.hs`, `src/Prodbox/Repo.hs`, binary-sibling `prodbox.dhall`, `prodbox-config-types.dhall`, `test-secrets-types.dhall` | Phase 1 |
| Host and Kubernetes helpers | `src/Prodbox/Host.hs`, `src/Prodbox/K8s.hs` | Phase 1 |
| Container packaging and registry doctrine | `docker/`, `src/Prodbox/CLI/Rke2.hs`, `src/Prodbox/ContainerImage.hs`, `src/Prodbox/Lib/ChartPlatform.hs` | Phases 1-4 |
| Pulumi orchestration and YAML stack programs | `src/Prodbox/CLI/Pulumi.hs`, `src/Prodbox/Infra/`, `pulumi/aws-eks/Pulumi.yaml`, `pulumi/aws-eks/Main.yaml`, `pulumi/aws-test/Pulumi.yaml`, `pulumi/aws-test/Main.yaml`, plus per-run Pulumi state in the MinIO `prodbox-state` bucket (anchored to `.data/prodbox/minio/0`) | Phase 4 |
| DNS inspection | `src/Prodbox/Dns.hs` | Phase 2 |
| Shared public-edge route catalog | `src/Prodbox/PublicEdge.hs` | Phase 3 |
| Gateway runtime and packaging | `src/Prodbox/Gateway.hs`, `src/Prodbox/Gateway/Daemon.hs`, `src/Prodbox/Gateway/Peer.hs`, `src/Prodbox/Gateway/Types.hs`, `docker/prodbox.Dockerfile` (union runtime image) | Phase 2 |
| Formal verification | `src/Prodbox/Tla.hs`, `documents/engineering/tla/` | Phase 2 |
| Chart platform and retained state | `src/Prodbox/CLI/Charts.hs`, `src/Prodbox/Lib/ChartPlatform.hs`, `src/Prodbox/Lib/Storage.hs`, `src/Prodbox/PostgresPlatform.hs`, `src/Prodbox/Secret/VaultInventory.hs`, `charts/`, the active Vault chart-secret policy/role/service-account, Kubernetes-auth config, seed-bootstrap foundation, direct websocket OIDC `SecretRef.Vault` consumer, Keycloak / MinIO / VS Code Vault materialization jobs, gateway event/AWS/MinIO Vault consumers, the Patroni Vault materializer hook (Sprint `3.18`), the Sprint `3.19` removal of the legacy master-seed derivation path, and the Percona-operator-backed Patroni application-database contract | Phase 3 |
| Public workload runtime | `src/Prodbox/Workload.hs` | Phase 3 |
| Public-edge diagnostics | `src/Prodbox/Host.hs` | Phase 5 |
| Onboarding and AWS administration | `src/Prodbox/Aws.hs`, `src/Prodbox/AwsEnvironment.hs`, `src/Prodbox/CLI/Parser.hs`, `src/Prodbox/Native.hs` | Phase 7 |
| Test harness and quality gate | `src/Prodbox/BuildSupport.hs`, `src/Prodbox/CheckCode.hs`, `src/Prodbox/TestRunner.hs`, `src/Prodbox/TestValidation.hs`, `src/Prodbox/Effect.hs`, `src/Prodbox/EffectDAG.hs`, `src/Prodbox/EffectInterpreter.hs`, `src/Prodbox/Prerequisite.hs`, `src/Prodbox/Result.hs`, `src/Prodbox/Subprocess.hs`, `src/Prodbox/TestPlan.hs`, `test/` | Phases 1, 4, and 5 |

## Historical Execution Record

**Superseded paused checkpoint (2026-08-16; not a resume instruction).** The recorded remaining
target included a credential-session-bound Provider operation, causal registered-stack generation,
terminal-audit reservation/read-back, Cascade pre-uninstall authority, and a locked
`Prepared -> Absent` host record created before uninstall and read back afterward. It also retained
the old public writer until the later single-writer cutover. The current execution order is only
[README.md → Resume Here](README.md#resume-here).

### Prior execution history

**Own-surface reopens, 2026-08-10 (Standard A/N, recorded here per Standard C).** A live
`prodbox test all --substrate aws` run failed at the `bootstrap-broker` Helm release on eight
consecutive attempts. The chart permits Kubernetes API egress on TCP `443`; kube-proxy DNATs the API
Service to its endpoint on `6443` before the CNI evaluates egress, so the rule matches nothing, the
broker answers `/healthz` 200 and `/readyz` 503, and `helm upgrade --wait` expires at thirty
minutes. Two phases reopen on their own surfaces:

- **Phase `3` ✅ Reclosed (2026-08-11)** — Sprint `3.34` ✅ owned the coordinate and the chart-lint region and is Done. The
  coordinate has no compiled owner (`grep -rn "6443" src/` returns one hit, a kubeconfig
  string-match), so three sites each author their own; and `apiEgress`, the one place the rule is
  generated from a live observation, is wrong in **both** coordinates because it observes the
  Service (pre-DNAT) while policy is evaluated post-DNAT. The sprint derives the coordinate from
  `endpoints/kubernetes` and widens the chart lint to every repo-owned template, closing a region in
  which no gate reads a `networkpolicy.yaml` for content at all. **It edits a live production
  rendering path**, so the next Standard-P qualification run must exercise the post-`3.34` rendering.
- **Phase `2` ✅ Reclosed (2026-08-11)** — Sprint `2.42` ✅ owned the broker's discarded transport
  failure and is Done. The chart caused the outage; this surface is why it cost eight runs to find,
  because `Left _` reduced a dropped packet, a `403`, and a `404` to one sentence while `/healthz`
  answered 200 ([chaos_hardening_doctrine.md § 23](../documents/engineering/chaos_hardening_doctrine.md)
  corollary 2). The reason is now classified at the request helper and carried by all six sites;
  the classifier renders fixed labels only, so an operator-visible readiness body cannot leak the
  bearer token the request carries. It does not fix the cause, which landed as Sprint `3.34` ✅.
- **Phase `2` ✅ Reclosed again (2026-08-11)** — Sprint `2.43` ✅ **Done** closes three broker-readiness
  defects that Sprint `3.34` uncovered by fixing the NetworkPolicy: with API calls succeeding for the
  first time, a self-observation selector missing the repo-wide `prodbox-` prefix, a `PodWire`
  decoder requiring the `apiVersion`/`kind` Kubernetes omits on `PodList` items, and a
  controller-image check requiring a `:latest` tag the harness overrides on both substrates each
  became reachable in turn. Registered rather than patched silently (Standard L), then landed.

Governance Sprint `0.26` ✅ **Done (2026-08-10)** lands the doctrine both implement — § 24, *an
observation has a layer* — on the already-reclosed Phase `0` documentation surface with no reclose
event, and corrects in place a chart-doctrine claim that was wider than the region enforcing it. The
lint `3.34` adds closes drift, not correctness, and is not credited with catching this outage.

**Own-surface reopens, 2026-08-05 (Standard A/N, recorded here per Standard C).** Sprint `0.21`
struck the `**Referenced by**:` metadata field and added two governed-document lint gates; the
illegal-state topology it accompanies
([chaos_hardening_doctrine.md § 21](../documents/engineering/chaos_hardening_doctrine.md)) reopened
four phases on their own surfaces, each on verified evidence rather than intent:

- **Phase `1` 🔄 Active** — Sprint `1.76` ✅ **Done (2026-08-07)**; Sprint `1.77` open. Readiness
  evidence for a conditional-write capability was constructible from a string literal. It no longer
  is: the witness is opaque behind a `dev check`-enforced minting allowlist, the deep readiness slot
  has its own result type so a shallow probe is a type error rather than a runtime rejection, and
  the witness carries the instant the write landed so the freshness window bounds the proof rather
  than the question. The gateway CAS lane that had been faking its witness now exists end to end —
  the conditional-put version the store returns, discarded at every call site, reaches the daemon,
  which projects it for the host to read. Sprint `1.77` ✅ **Done (2026-08-07)** likewise: retryability is now a
  property of the (operation, error) pair — a timeout on a mutating call is *indeterminate*, not
  transient, and repeating one requires an idempotence witness the type system demands — and jitter
  exists, where before every retrier in the tree shared one deterministic schedule and N clients
  failing against one dependency re-collided on every attempt.
- **Phase `2`** — Sprints `2.39`, `2.40`, and `2.41` are all ✅ **Done (2026-08-07)**. `2.39`'s last deliverable, the conformance gate, now enforces the constant-time `/readyz`
  contract structurally instead of describing it, and its live reproducer stays 🧪 Standard-O.
  `2.40` replaces the authored `3 * period` staleness bound — which failed its own arithmetic, so a
  healthy broker projected `Starting` for most of every cycle and evicted itself — with a bound
  *derived* from the observer period and the per-pass budget by a hidden-constructor schedule.
  `2.41` ✅ **Done (2026-08-07)** collapses the emitter's three disagreeing cells into one value —
  `Ready` with no runtime was reachable on the *deployed* path — and replaces the monotone
  workers-started flag, written once before any worker existed, with a heartbeat-bounded roster whose
  supervisor is the only way to run a worker.
- **Phase `3`** — Sprints `3.31` and `3.32` are both ✅ **Done (2026-08-07)** and the reopen closes.
  `3.32` makes a typed DNS destroy consume the ownership authority the running process holds rather
  than compare two copies of the coordinate's owner a single caller supplied; the authority's minter
  is a total `RuntimeRole × Substrate` table, and neither cert-manager owner is in its range, so the
  cross-substrate deletion the sprint named cannot be expressed at all. Its documentation half
  refuted the sprint's premise for a second time: prodbox — not Percona PGO — is the authority for
  the three Patroni passwords, and the one mirror that exists is chart-local and runs Vault →
  Secret.
- **Phase `4` (2026-08-09 own-surface reopen, 🔄 Active)** — Sprints `4.62`–`4.66` are ✅ **Done** and
  the reopen stays open, because unowned `Pending Removal` rows this phase owns remain. `4.66` is the
  one that mattered on the wire: `httpReasonPhrase` mapped six statuses while the interpreters emit
  ten, so the control plane was writing `HTTP/1.1 403 Status`. `4.65` gives a refusal back its
  structured reason through a required positional argument — its ledger row prescribed a module that
  has never existed and a mechanism `dev check` forbids, so following it would have failed the build.
  `4.64` makes the admission reset `4.61` fixed by hand unnameable, using the type and the existing
  allowlist rather than a new lint. `4.63` decides the global ledger's CAS verdict at all four sites
  its row said was one. Remaining: the unbounded control-plane accept loop and its missing deadlines
  (Standard-P queueing/admission), the producer-side `ReplyStatus` migration, the two untyped Route 53
  writers, the `TargetSinkCasRequest`/`TargetSinkRecord` constructor exports, the non-CAS
  `vaultKvWriteV2` export, and the discarded final-slice admission set.
- **Phase `4` (2026-08-08)** — Sprints `4.55`, `4.56`, and `4.59` are all ✅ **Done** and that reopen
  closed. `4.55` gives the five control-plane roles the treatment Sprint `2.39` gave the Bootstrap
  Broker: readiness is `STM`-typed cached facts, so backend I/O on a `timeoutSeconds: 1` probe path
  no longer type-checks, and the `m Bool` seam is gone. Its stated counts were wrong for every role
  and are corrected — the worst offenders were the two the sprint said ran nothing: an
  `aws sts get-caller-identity` subprocess, and up to 32 sequential Vault KV reads whose healthy path
  was the slowest. `4.56` makes the admission ticket the repository already minted a required
  argument of the act instead of a value discarded one line later. `4.59` deletes the superseded
  in-controller Target write lane — minus two clauses of its own implementation list that source
  refuted.
- **Phase `5`** — Sprint `5.29` is ✅ **Done (2026-08-08)** and the phase closes. The DNS01 challenge
  record is registered before issuance, removed by an always-run cleanup node, and proven absent by
  an exact read-back in which "cannot observe" is not "absent". Its two premises were corrected
  against source: prodbox never writes the record, and the Challenge UID does not exist when the
  registration must happen.

No later phase blocks any earlier one; every entry above expands the phase's own owned surface, and
Phases `6`, `7`, and `8` remain closed. Deployment qualification is unchanged and still `pending` on
both substrates.

**Conversions and gate regions, 2026-08-08 (Standard C).** Twenty of 55
`prodbox test integration cli` / `env` cases were failing, and the cause reframes the four sprints
above rather than adding to them. Sprint `1.80` had made
`deployment.public_edge_advertisement_mode` a closed Dhall union — the § 21 class-D move, on the
field § 21 names as its own worked example — and applying it broke the twenty cases, surfacing as
`NoResponseDataReceived`. **This is a failure of MISU, not an absence of it**: five
minting-boundary gates, a Ring-1 `assert`, a Ring-2 decode gate and the `0.24` drift gate were all
in force, and each constrains a value *inside* `src/` while the defect lived at three conversions
out of it — a `ConfigFile` hand-authored as a Dhall string, a typed `Left` thrown as `ioError`, and
that exception escaping a socket handler before any byte was written.

Governance Sprint `0.25` ✅ **Done** records the doctrine on the already-reclosed Phase 0 surface
(no reclose event): `chaos_hardening_doctrine.md` gains **§ 23, "Conversions — where the moves
stop"**, § 22 gains a fourth honest consequence, § 21's "Neither needs new doctrine" is corrected in
place, and `resource_scaling_doctrine.md` § 2C gains **"The region of Ring 2"** — a ring is a
property of a type over a *compiled region*, and this repository's region excluded `test/`
entirely. **Phases `4` and `5` reopened on their own surfaces** for the code: Sprint `4.60` ✅ (a
response obligation, so "accepted a connection and answered nothing" stops being expressible) and
Sprint `5.30` ✅ (one Tier-0 encoder, the fixture decode failure kept as a value, `--enable-tests`).
Neither moves a Standard-P production-composition surface.

At that checkpoint, Phase `5` remained 🔄 Active on Sprint `5.31`; the integration suite had gone
**20 of 55 failing → 8 → 4**. The chain `5.31` uncovered is worth the space, because each link was
invisible until the one above it was fixed: a typed `AdmissionRefusal` discarded with a wildcard
made eight cases exit 1 in silence (§ 23 at the *step* boundary — `ExitCode` has no room for a
reason, and the renderer already
existed); returning the refusal instead of lowering it named a Phase-`4` production defect in one
run (admissions reset at every phase boundary, closed as Sprint `4.61`); and under that sat three
fixture drifts ending in the capacity drift Phase 5 had registered as silent — the fake LimitRange
declared the gateway at 250m where the plan projects 750m. The fixture's observed cluster state now
renders from the same projection the validator compares against. Four cases remained, each a distinct
named question.

**Sprint `5.31` closure, 2026-08-09 (Standard C).** Sprint `5.31` is ✅ **Done**, Phase `5` is
reclosed, and all code-owned phases `0`–`8` are closed. The four questions resolved as fixture
expectation drift: the fake cluster exposed three gateway Pods against an exact typed projection of
two; the transient primary image push retries and succeeds without selecting its fallback; config
setup is asserted through the derived Dhall union constructor and structural decoded value; and a
valid fixture subzone lets the AWS-IAM teardown case reach its intended refusal when the
authenticated Credential Provisioner is unavailable. Evidence: installed `cli`/`env` integration
**55/55** and canonical `prodbox test unit` exit 0 with main Hspec **3255/3255**. Clean-room home
and AWS deployment qualification remains `pending` on the separate Standards O/P axis.

**Tier-0 config audit, 2026-08-07 (Standard C).** An audit of the Dhall config surface asked whether
the design makes illegal state unrepresentable. For categorical state it largely does — closed unions wherever the legal set is a fixed
vocabulary — substrate, component identity, dependency-edge kind, readiness-probe kind, QoS
class, scaling policy, and secret-reference shape. For value-level state it does not, which is expected: Dhall has
no refinement types, and [resource_scaling_doctrine.md § 2C](../documents/engineering/resource_scaling_doctrine.md)
already names Ring 2 rather than Ring 1 as the ring that delivers the guarantee. Three governed
documents nonetheless carried claims that were false against source, corrected under governance
Sprint `0.23` on the already-reclosed Phase-0 documentation surface (no reclose event, as with
`0.18`–`0.22`). **Phase `1` gained Sprints `1.79`–`1.81`** on the surface it already had open, and all three are
✅ **Done (2026-08-07)**: the in-force config payload renderer omitted a field the Tier-0 renderer
preserves and is now derived from the same `Dhall.inject` mechanism; the two-value advertisement
enum carried as free text is now a closed Dhall union, so a misspelling fails the type check rather
than a string comparison; and the validator, a flat list that never mentioned the record, is now
total over it — as a positional pattern, because the field-named form the audit proposed turned out
not to force anything.
Sprint `0.24` ✅ closes the missing Tier-0 drift gate: `prodbox dev check` now decodes the
binary-sibling `prodbox.dhall` and holds it to the canonical re-render of the record it decodes to,
naming the drifted field. Absence stays silent and a malformed file is a distinct finding. The
mutation exercise established both halves of its reach — a hand-edited resource plan is caught,
because the emitted `concurrentDraws` list it leaves stale is the Ring-1 `assert`'s own input, and a
round-tripping primitive edit is not, which is registered as an unowned follow-up carrying a
Standard-P generated-config-identity consequence rather than folded in silently.

**No phase reopens on this account, and no prior closure was falsified.** Each candidate claim was
read against its cited evidence: the `decode . encode == id` claim covers the Tier-0 record's total
`Dhall.inject` path; the Phase-7 drift guards state their scope as a *default* config; the Phase-5
sweep over the payload renderer is a SecretRef scan that by construction cannot observe a missing
field. Every claim held within its stated scope. The defects sit in gaps no claim covered, which is
a coverage failure rather than a false-evidence failure — and recording that distinction matters,
because manufacturing corrections where none are owed is the same dishonesty in the other direction.

As of the 2026-07-26 forced-shutdown counterexample, Phases `0` and `1` are reclosed and Phase `2`
is reopened on Sprint `2.36`. Sprints `1.61`–`1.67`,
the code-local Sprint `2.32` emitter target, and Sprint `2.33` (minimal Bootstrap Broker + gateway
scope cut) are Done, so every Phase-2 sprint (`2.30`–`2.35`) is closed. Substrate-neutral Kubernetes
reachability proves the selected cluster through `ToolKubectl` plus `kubectl cluster-info`, while
local RKE2 file/service facts remain explicit home-local nodes. Phases `3`–`8` retained the Planned,
Active, or forward-only Blocked states in the then-current alignment table, with Sprint `3.26`
unblocked by the completed `2.33`. Deployment qualification was pending on both substrates. This
paragraph and the narrative below are closure history, not a current-status ledger. Current status
is only [README.md → Resume Here](README.md#resume-here).

The pre-reopen Phases `0`–`7` remain closed on the implemented repository architecture. Phase
`0` has now re-closed after Sprints `0.2`–`0.7` landed the doctrine-adoption planning work
(Sprint 0.6 introduced the substrate doctrine and renamed phase-5 and phase-7 to their
substrate-aware names; Sprint 0.7, May 20, 2026, added the non-TTY guardrails on the
operator-interactive command surface). Phases `1`–`4` have also reclosed on the downstream
implementation scope scheduled by those sprints: Sprints `1.6`–`1.27`, `2.9`–`2.16`,
`3.8`–`3.12`, and `4.5`–`4.8` are locally validated and doc-aligned, and Sprint 1.2 was
revised May 20, 2026 to replace the external `dhall-to-json` subprocess decode bridge with
in-process decoding through the native Haskell `dhall` library (`Dhall.inputFile auto`).
Phase `5` reclosed after Sprint `5.5` added the port-80 HTTPS-redirect listener (May 13,
2026). Phase `7` reopened for substrate parity and is now reclosed on that surface: Sprints
`7.5.a`–`7.5.c.iv`, `7.5.c.v.b`–`7.5.c.v.f`, and `7.5.c.v` are `Done` after the June 5,
2026 live AWS run proved the AWS substrate through admin-routes, public DNS, lifecycle, and
postflight cleanup. Sprint `7.6` (orphan-safety
refuse-path + auto-destroy) and Sprint `7.7` (generalized `aws teardown` +
`PulumiResiduePolicy` ADT + harness teardown bug closure + admin-credential prompt UX) are
both `Done` (May 19, 2026). Phase `8` opened May 18, 2026; Sprints `8.1`–`8.4` are `Done`,
the targeted AWS `keycloak-invite` proof is green, Sprint `8.5` POST/OIDC code has local unit
proof through the public-edge certificate status-patch guard and TLS Secret retention fix, and
`8.5`–`8.6` carry the remaining operator-driven live OIDC and aggregate closure work. On
2026-06-06 Phases `4` and `7` reopened again (Sprints `4.24` and `7.11`) and Phase `8` gained
Sprints `8.7`/`8.8` to reclassify the public-edge production certificate as a `LongLived`,
rate-limit-safe resource (the 2026-06-06 attempt rendered two ACME issuers with a staging issuer
for rebuild churn; that two-issuer/`IssuerClass` model was reverted 2026-06-07 to one ZeroSSL
issuer with S3 retain-and-restore); see the [Historical Alignment Record](#historical-alignment-record) note for the
reopening rationale. **Phases `4` and `7` reclosed 2026-06-07** when Sprints `4.24` and `7.11`
landed on their code-owned surfaces (the certificate is a registered `LongLived` managed resource;
the ACME runtime renders one ZeroSSL `ClusterIssuer` — `zerossl-dns01`, EAB-authenticated, with a
DNS-01 Route 53 solver — plus the substrate-scoped S3 cert-retention key scheme and access path;
the two-issuer model these sprints first added was reverted 2026-06-07); Phase `8` stayed open at
that checkpoint for Sprints `8.7`/`8.8` and the live `8.5`/`8.6` proofs, all of which later closed.

- Phase 0 defines the canonical plan suite and cleanup ledger.
- Phase 1 owns the operation-indexed capability graph, opaque references, absolute-deadline and
  service-capacity algebra, the resource-envelope over-commitment proof, native object-store protocol, managed Vault-session boundary, and the
  substrate-neutral Kubernetes prerequisite boundary: `K8sClusterReachable` is
  `ToolKubectl` plus authoritative `kubectl cluster-info` against the selected substrate
  kubeconfig, while RKE2 file/install/service nodes remain explicitly home-local. It also owns the CLI,
  direct-Dhall config contract, `.build/prodbox` artifact contract, the
  Haskell test and quality framework, the local edge foundations, the one-host config contract,
  and config-selected MetalLB BGP support. The Phase `1` doctrine-adoption reopen covers
  Sprints 1.6–1.27, including `CommandSpec`, Plan / Apply, Subprocess ADT, prerequisite
  remedy-hint contract, the lint/generated-section/forbidden-path stack, the tasty stanza
  migration, capability classes and `AsServiceError`, `RetryPolicy`, `Recoverable` / `Fatal`
  errors, naming helpers, GADT-indexed state machines, one-shot output discipline with
  `--format` / `--color` / `--no-color`, the shared one-shot `Env` plus `ReaderT App`, the
  pinned style-tools sandbox and custom nesting warnings plus negative-space symbol
  rules refusing `forkIO`, `unsafePerformIO`, and module-level `IORef` in daemon paths, the
  aggregate `prodbox test lint` dispatch with lint-first ordering, the
  `trackingGeneratedPaths` registry plus renderer determinism property test, the
  standardized library audit of `prodbox.cabal`, the residual doctrine cleanup in
  Sprint 1.23 covering the parser `--foreground` default plus self-daemonization-forbidden
  rule and the explicit cross-language-types generation deferral, and — added by Sprint 0.3 —
  the durable CLI documentation artifacts under `documents/cli/`, `share/man/`, and
  `share/completion/` (Sprint 1.24), the `execParserPure` parser-test category in the
  `prodbox-unit` stanza (Sprint 1.25), and the `renderError` error-rendering boundary
  discipline plus hlint rules refusing `print`, `exitFailure`, and direct terminal
  formatting outside the dedicated output layer (Sprint 1.26). Sprint 0.4 adds Sprint 1.27
  (cabal-manifest `tested-with: ghc ==9.12.4`, `with-compiler: ghc-9.12.4`, the literal
  `Cabal 3.16.1.0` reference, and the library-first / thin-`Main.hs` audit) and threads
  round-3 extensions through Sprints 1.6, 1.8, 1.10, 1.11, 1.12, 1.14, 1.15, and 1.21
  binding the `CommandSpec` / `OptionSpec` record shape, daemon-as-typed-`Command`
  dispatch, forbidden subprocess primitives (`callProcess`, `readCreateProcess`, direct
  `System.Process` constructors), the thirteen minimum `fourmolu.yaml` settings, the
  canonical property-test invariants (`decode . encode == id`, `render is deterministic`,
  `parser roundtrips`), the service-error newtype inventory (`MinIOError`, `RedisError`,
  `PgError`), the `AppError` record shape (`errorKind`, `errorMsg`, `errorCause :: Maybe
  SomeException`), the naming-helper signatures with DNS-1123 / 63-character constraints,
  and the enumerated forbidden renderer inputs.
- Phase 2 owns the single-writer emitter actor/journal, Bootstrap Broker extraction, gateway scope
  reduction, the gateway runtime, DNS inspection surface, the single-record Route 53 doctrine,
  and the TLA+ validation entrypoint. Sprint `2.31` replaces the uptime-growing hot log/transport,
  proves `/v1/state` is bounded independently of uptime, and recloses Phase `2`. Its
  retained surfaces include the native `gateway-partition` validation path, peer-transport
  gossip through `Prodbox.Gateway.Peer`, runtime claim/yield emission under the `canWriteDns`
  predicate, operator-verifiable bounded-clock-skew enforcement, config-relative trust-material
  validation, listener-host closure from Orders, Orders-version coordination across the mesh, and
  the host-info parser cleanup that limits `parseTimedatectlNtpDisposition` to the supported
  `System clock synchronized` field. The Phase `2` doctrine-adoption reopen covers Sprints
  2.9–2.16, including the explicit daemon lifecycle with worker loops wrapped in
  `try`/`catch` + bounded retry-with-backoff, `/healthz` / `/readyz` / `/metrics` endpoints
  with response shapes captured as golden tests, the `BootConfig` / `LiveConfig` split with
  mounted-Dhall file-watch reload and atomic-swap discipline on `envLiveConfig` (boot-field
  changes drain and exit so the kubelet restarts the Pod; live-field changes hot-reload in
  place; see [config_doctrine.md](../documents/engineering/config_doctrine.md)), `co-log`
  structured logging, test hooks in `Env`, the `prodbox-daemon-lifecycle` stanza asserting
  single SIGTERM begins drain and second SIGTERM (or drain deadline) forces exit, the
  daemon CLI plumbing (`--config <path>` is the sole startup knob; `--log-level`,
  `--port`, `--node-id`, `--foreground`, and `PRODBOX_*` env-var precedence are forbidden
  per the config doctrine), and the at-least-once event-processing module
  (`src/Prodbox/Daemon/Events.hs`) introduced in Sprint 2.16 covering `StoredEvent`,
  `recordEvent`, `markEventProcessed`, `fetchUnprocessedEvents`, and the idempotent
  `EventHandler` precondition. Sprint 0.3 extends Sprints 2.9–2.12 with the audit-driven
  residue: the default 30 s drain deadline plus explicit `bracketOnError` on
  external-side-effect resources (Sprint 2.9), the `envMetrics :: MetricsRegistry` typed
  daemon `Env` field backing `/metrics` (Sprint 2.10), the STM broadcast channel for
  `LiveConfig` subscribers plus the prescribed on-disk Dhall file shape (Sprint 2.11), and
  the daemon log level refreshed from `LiveConfig` on every file-watch reload (Sprint 2.12).
  Sprint 0.4 extends Sprints 2.9, 2.11, 2.12, 2.13, and 2.14 with the round-3 residue:
  the enumerated structured-concurrency primitive set `withAsync` / `race` /
  `concurrently` / `replicateConcurrently` (Sprint 2.9); the file-watch reload trigger
  (replacing the previously-scheduled forbid-fsnotify / forbid-inotify / forbid-mtime
  clause, superseded by [config_doctrine.md](../documents/engineering/config_doctrine.md)
  and tracked in legacy-tracking-for-deletion.md), the typed Dhall field
  `schemaVersion : Natural` with mismatch-as-parse-failure, and the reload procedure
  bound step-by-step (Sprint 2.11); the typed field helper
  `field :: (Aeson.ToJSON a) => Text -> a -> (Text, Aeson.Value)` plus `logStructured`,
  `logDebug`, `logInfo`, `logWarn`, and `logError` wrappers (Sprint 2.12); the
  production-no-op / test-injected hook contract pattern (Sprint 2.13); and the
  `/healthz` / `/readyz` / `/metrics` response shapes captured as golden tests inside the
  lifecycle stanza (Sprint 2.14).
- Phase 3 owns the separately resourced Bootstrap Broker, Lifecycle Authority, Target Secret Agent,
  Authority Backup and TLS Retention Adapters, fenced Provider Worker, permit-created Credential
  Provisioner/External Material Ingress/Admin Action Runner, and identity-bound emitter-journal workloads plus the chart
  platform, retained state model, and the bootstrap-owned ordinary teardown recovery projection and
  external CLI ServiceAccount/RBAC whose lifetime is independent of Gateway/applications,
  supported public workload delivery, and
  the Percona-operator-backed Patroni PostgreSQL doctrine for Helm-managed workloads. The Phase
  `3` surfaces include the root-chart-only public `prodbox charts ...` surface, the JWT-protected
  API route, the Redis-backed
  WebSocket runtime, the shared public-workload runtime, multi-replica public workload scaling,
  the mixed-auth doctrine boundary between Envoy-managed browser auth and app-managed OIDC
  workloads, the explicit JWT carrier plus Keycloak JWKS-availability boundary, the shared-host
  Keycloak contract, real WebSocket upgrade handling, one-connection-per-pod lifetime,
  readiness-based drain, and path-routed MinIO admin delivery. The Phase `3`
  doctrine-adoption reopen has closed across Sprints 3.8–3.12, including smart constructors
  for paired chart resources, capability classes on chart Redis and Postgres call sites,
  reconciler discipline on `prodbox charts reconcile` / `delete`, `--dry-run` on chart operations, the
  `prodbox dev lint chart` Helm-chart structural-invariants linter in Sprint 3.12, and
  marker-delimited route-inventory generation from `src/Prodbox/PublicEdge.hs` into chart
  artifacts via the `generatedSectionRule` registry. Sprint 0.4 extends Sprint 3.10 with
  the named forbidden reconciler flags `--force` and `--reinstall` plus the forbidden
  sister commands `install`, `upgrade`, `repair`, and `force-install` on the chart surface.
- Phase 4 owns the pure lifecycle-indexed registry, exact keyed resource/checkpoint/audit observation
  boundary, desired-absence decisions, result-indexed programs, generic durable CleanupRun kernel,
  proof-carrying cascade completion, durable Lifecycle Authority aggregate, operation journal/outbox,
  immutable checkpoint references, target delivery, authority-epoch cutover, in-cluster `registry:2`
  lifecycle hardening, the bounded MinIO/storage bootstrap
  exception, the public AWS-validation Pulumi surface, lifecycle-owned bootstrap DNS
  and ACME projection, Python removal, and the native-host-architecture container-build doctrine.
  The Phase `4` lifecycle bootstraps the registry's MinIO storage, reconciles the single-binary
  registry, and keeps its later AWS-
  validation and Python-removal surfaces closed on the supported path. Sprint 0.4 extends
  Sprint 4.5 with the same forbidden-flag and sister-command discipline on the lifecycle
  reconciler; the one-cycle `install` alias has been retired, and `install`, `upgrade`,
  `repair`, and `force-install` are rejected at parse time.
- Phase 5 owns the independent frozen teardown reference oracle and fault/restart matrix plus, in
  Sprint `5.36`, the `TestRunner` client of the Phase-4 cleanup kernel; it also owns the temporal
  CPU/queue/deadline/fault oracle, public-edge diagnostics, and external proof on Route 53, Envoy
  Gateway, Gateway
  API, certificate readiness, and external browser validation. It includes API, WebSocket,
  MinIO route classification plus named external proofs for those workloads. Sprint
  `5.5` closes this phase's redirect-only port `80` handling and proof while preserving HTTPS as
  the only application-traffic route.
- Phase 6 owns home-substrate cutover/rollback and prerequisite qualification evidence, including
  the one-writer old→recover-to-clean teardown activation, interruption-prefix resume, legacy
  absence scan, and two-cycle installed-binary handoff; it also owns the destructive
  clean-room rerun and zero-Python repository handoff criteria, proved through consecutive
  aggregates, always-run postflight restore, `config show`, `config validate`,
  `edge status`, and supported-path repository review gates for placeholder-domain and Python
  residue. Sprint `8.12` is the sole final deployment-qualification owner for both substrates after
  the later shared SES workflow revision.
- Phase 7 owns AWS Broker/Target-Agent/Gateway parity, exact transport to the single retained home
  Lifecycle Authority, independent per-stack/provider observers, write-ahead ownership manifests,
  controller-family desired absence, provider-issued EKS drain sessions, and AWS adapter
  prerequisite evidence for Sprint `8.12`; it also owns interactive
  onboarding, IAM automation, quota management, and the temporary-admin credential proof harness
  on one canonical public hostname with no placeholder-domain residue.
- Phase 8 owns the durable SES specialization over the generic Lifecycle Authority: provider
  revision, narrow mutation fence, semantic convergence, SMTP generation, target-delivery outbox,
  and invite-flow fault campaign.

## Hard Constraints

- The only supported public CLI is `prodbox`.
- The rewrite preserves the full supported command matrix in
  [../documents/engineering/cli_command_surface.md](../documents/engineering/cli_command_surface.md)
  unless a later plan revision changes it explicitly.
- The only supported local lifecycle host runtime is `Ubuntu 24.04 LTS` with systemd.
- The host build root is `.build/` with the operator-facing binary at `.build/prodbox`, enforced
  by the canonical `cabal build --builddir=.build exe:prodbox` invocation plus a copy step.
- The container build root is `/opt/build`, and the only supported home for repository-owned
  Dockerfiles is `docker/`.
- Repository-root Dockerfiles are not part of the target architecture.
- `prodbox dev check` must fail on governed doctrine-alignment violations, not only on
  formatter, linter, build, or operator-binary sync failures.
- Every custom Dockerfile needing Haskell builds is single-stage from `ubuntu:24.04`, installs
  `ghcup` in-image, pins GHC `9.12.4`, and does not create symlinked Haskell tool shims. No
  supported browser-facing auth path depends on a repository-owned nginx auth-proxy image.
- When the pinned Haskell toolchain changes, `prodbox.cabal`, `cabal.project`, and the canonical
  build/test surfaces must be explicitly upgraded in the same change, including any required
  cabal-bound changes and full canonical validation reruns.
- The executable-sibling Tier-0 `prodbox.dhall` is the supported host seed/bootstrap source. Once
  established, the Lifecycle Authority generation/digest/reference is the in-force config SSoT and
  selects one immutable Vault-Transit-enveloped MinIO blob; a blob alone is never current.
- The supported configuration handoff is direct `Dhall -> Haskell types`; no supported command or
  validation path may create `prodbox-config.json`, and `prodbox config compile` is not part of
  the target command surface.
- There is exactly one runtime ingress by which elevated/admin AWS bytes enter prodbox: an
  authenticated `SecretRef.Prompt` stdin stream with exactly three disjoint consumers: the
  permit-selected Credential Provisioner for identity work, the permit-selected Admin Action
  Runner for its one closed action, and the post-export Decommission Runner for a signed manifest.
  `prodbox config setup` is not credentialed, normal provider work consumes an already sealed
  Lifecycle-provider generation, and `prodbox nuke` derives authority only from its external
  manifest while the prompt supplies transport credentials. Prompt bytes are never written to
  `prodbox.dhall`, Vault, authority state, Kubernetes objects, argv/environment, logs, or disk.
- Stored admin credentials are disallowed in `prodbox.dhall`; there is no production
  config-backed admin path. The only admin credential outside the prompt is the test-harness-only
  `TestPlaintext` fixture `aws_admin_for_test_simulation.*`, which lives in `test-secrets.dhall`
  (never imported by `prodbox.dhall`, never read by a production binary, never in Vault) and
  whose sole purpose is to simulate the interactive prompt so the suite can drive admin-credentialed
  flows non-interactively. See
  [vault_doctrine.md §§3/4/13](../documents/engineering/vault_doctrine.md) for the `SecretRef`
  model, config split, and classification.
- The named and aggregate IAM validation surfaces share one joint idempotent harness that drives
  the same durable setup operation from `aws_admin_for_test_simulation.*`, registers cleanup before
  mutation, proves each role-specific generation, and deletes/tombstones Operational generations
  on every exit. LongLived Authority-backup, TLS-retention, Gateway-DNS, home-DNS01, and SES-SMTP
  generations plus schema-bound custody receipts are retained and verified, not deleted.
  No role can authorize or stand in for another.
- Full cluster delete preserves the configured manual PV root, including the durable Vault PV under
  `.data/vault/vault/0` and the MinIO PV under `.data/prodbox/minio/0`; chart secrets are
  Vault-backed and the master-seed derivation baseline has been removed.
- Local-only delete may uninstall without AWS cleanup and makes no AWS absence claim. Cascade must
  repair or reinstall its bootstrap-owned minimal recovery profile, resume the durable run, close
  every exact per-run/family obligation, audit normalized escapees, and independently receipt the
  report before local uninstall. Incomplete cleanup keeps the profile/credentials live and returns
  `CleanupRunId`.
- Checkpoint usability, exact provider resource truth, and terminal escape audit are nominally
  distinct. A global audit cannot select a stack, a tag row is not a resource, and one answer cannot
  be copied across resource keys. Static lifecycle/surface legality may be type-indexed; external
  observations remain flat exhaustive ADTs.
- Secrets must never appear in `prodbox.dhall`, generated configs, logs, or committed Dhall;
  they are carried only as typed `SecretRef` references resolved through Vault. A sealed Vault must
  leave no secret, no active Dhall, no Pulumi state, and no downstream-cluster metadata extractable
  from the retained durable data — the fail-closed invariant of
  [vault_doctrine.md §2](../documents/engineering/vault_doctrine.md#2-the-fail-closed-invariant)
  (scheduled across Sprints `0.12`, `1.35`–`1.37`, `3.17`–`3.20`, `4.29`–`4.33`, `5.8`,
  `7.14`–`7.15`, `8.9`; the 4.29 lifecycle/PV foundation, 4.33 sealed-state gate/redaction
  surface, 5.8 code-owned validation surface, and 7.14 decrypt-to-scratch wrapper/read/migration
  paths have landed. The home whole-system sealed-state proof passed; AWS/federation variants
  remain separate non-blocking axes).
- Direct public-registry pulls are permitted only for the bounded MinIO/storage dependencies needed
  to bootstrap the in-cluster `registry:2` service.
- Every later Helm deployment must obtain its images through that registry.
- `prodbox` must idempotently ensure required public images are present in the registry before they
  are referenced by later supported cluster workloads.
- Supported custom-image builds and registry publication use only the native architecture of the
  machine running `prodbox`: `amd64` hosts build `amd64` images, and `arm64` hosts build `arm64`
  images.
- Native `arm64` publication works on native `arm64` Docker daemons. `docker buildx`,
  cross-arch emulation, and mixed-arch clusters are unsupported on the canonical lifecycle,
  gateway, and chart-delivery path.
- All supported Patroni use must flow through the cluster-wide Percona operator installed on the
  canonical lifecycle path.
- The self-managed public edge target uses MetalLB, Envoy Gateway, Gateway API, cert-manager, and
  Keycloak-backed edge auth rather than Traefik `Ingress` plus `vscode-nginx`.
- Supported public workloads and operational dashboards route only through Envoy on the configured
  shared hostname. The supported auth doctrine keeps the token carrier
  explicit across those paths: bearer tokens on JWT-protected routes, explicit browser return
  paths for proxy-auth surfaces, and workload-owned carrier or session state only where a route
  still needs direct-OIDC behavior behind the same host.
- Keycloak-backed public workloads must stay proxy-aware behind Envoy on the shared hostname,
  including issuer alignment, forwarded `X-Forwarded-*` header compatibility, and no supported
  public management or health route exposure unless a later doctrine revision makes that exposure
  explicit. Keycloak availability may gate login, refresh, and JWKS refresh, but the steady-state
  JWT hot path at Envoy must not depend on per-request Keycloak calls while cached signing keys
  and unexpired tokens suffice.
- The supported public-host doctrine uses one shared hostname, one DNS entry, and one
  certificate.
- Redis may appear only as repo-owned shared app state for supported realtime or rate-limit
  workloads; it is not part of Envoy JWT validation, and the current supported worktree does not
  yet ship a standalone external rate-limit service surface.
- Supported public API and admin routes must validate JWTs locally at Envoy from Keycloak issuer
  metadata and signing keys, with explicit bearer-token carriage, route-level RBAC, and
  JWKS-discovery ownership, rather than through per-request identity-provider lookups or Redis.
- Public listener TLS terminates at Envoy on the supported path. Backend TLS or mTLS is not part
  of the current chart-workload contract unless a later plan revision expands it explicitly.
- Supported WebSocket workloads authenticate at connection setup, keep reconnect-safe state
  outside the pod, keep each live upgraded connection pinned to one selected backend pod until
  disconnect, define token-expiry and authorization-change behavior explicitly, use readiness-
  based drain before pod exit, and leave per-message authorization to the application workload
  when message-level permissions are finer-grained than the edge can enforce.
- Every supported Helm-managed PostgreSQL deployment must be external, Percona-operator-backed
  Patroni HA with exactly three PostgreSQL replicas, synchronous replication, and no embedded
  chart-local PostgreSQL subchart.
- The `prodbox` surface remains the exclusive AWS mutation boundary. Pulumi is the normal fenced
  provider interpreter; when both checkpoint copies are unusable, only the lifecycle core's bounded,
  admin-confirmed ownership-manifest program may perform native desired absence. Bootstrap DNS
  reconcile and ACME `ClusterIssuer` projection remain separately lifecycle-owned in
  `src/Prodbox/CLI/Rke2.hs`.
- No supported Pulumi program or orchestration path may depend on Python.
- The only supported gateway steady state is inside the cluster as a Kubernetes workload.
- The gateway daemon, `prodbox gateway status`, and daemon config parsing expose a `/v1/state`
  projection bounded independently of uptime, keep constant-time health endpoints separate, and
  match the Orders/timing contract in
  `documents/engineering/tla_modelling_assumptions.md`.
- The gateway daemon must materialize peer transport from the certificate, key, CA, and socket
  fields already retained in `DaemonConfig` and `Orders`, so `stateLastHeartbeatTimes` is updated
  from inbound peer events rather than from the local heartbeat loop alone. The canonical target
  is signed per-emitter sequence state plus vector-cursor delta gossip and bounded checkpoints, not
  an append-only full-log transport; `/v1/state` exposes bounded per-peer transport health.
- The gateway daemon must emit signed `Claim` and `Yield` events on owner transitions and gate
  Route 53 writes on a credential-ready runtime equivalent of the modelled `CanWriteDns`
  predicate, so `ClaimPrecedesWrite` and `YieldPrecedesReclaim` hold on the bounded semantic event
  projection, ambient AWS state cannot confer authority, and a stale owner cannot reclaim DNS
  write authority without first observing its own yield superseded by a fresh claim.
- The supported-host gate must fail fast on unhealthy NTP synchronization, the gateway daemon
  must record the maximum observed inter-node clock skew on `/v1/state` and refuse inbound
  heartbeats whose timestamps exceed the documented bound, and the architecture and TLA+
  correspondence docs must name that bound, the operator response, and how the model's
  bounded-delay assumption maps to a runtime-enforced skew limit.
- Orders documents must carry a monotonic version field, daemons must reject inbound peer events
  from a peer presenting an older Orders version, a new Orders version must propagate through the
  bounded per-emitter/vector-cursor delta surface and be adopted by every live daemon before the next election tick,
  and a daemon rebooting against a stale Orders version must refuse to claim ownership until its
  Orders view catches up.
- The only supported DNS model is one explicit Route 53 record for the configured served FQDN;
  wildcard public DNS and per-service public hostnames are not part of the supported
  architecture.
- The supported public workload catalog includes the cluster-backed `vscode` stack, a
  JWT-protected API route, a WebSocket route, and path-routed operational dashboards; none may
  depend on app-local nginx auth proxies or dedicated public subdomains.
- `example.com` must be completely removed from the supported codebase, defaults, fixtures, and
  documented runtime contracts.
- Final handoff requires a destructive rerun from full local delete through final AWS teardown on
  the Haskell stack with no Python implementation dependency.
