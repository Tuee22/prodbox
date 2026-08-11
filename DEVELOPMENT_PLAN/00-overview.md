# prodbox Development Plan - Overview

**Status**: Authoritative source
**Supersedes**: N/A
**Generated sections**: none

> **Purpose**: Provide the target architecture, current baseline, clean-room sequence, and hard
> constraints for the Haskell rewrite of `prodbox`.

## Vision

Build a clean-room Haskell `prodbox` repository with:

1. One explicit `prodbox` CLI surface implemented in Haskell.
2. One supported local lifecycle operator environment: `Ubuntu 24.04 LTS` with systemd. This
   Ubuntu-only host gate is generalized to a multi-OS host-provider model (Linux-native, macOS via a
   Lima VM, Windows via a WSL2 distro) per
   [host_platform_doctrine.md](../documents/engineering/host_platform_doctrine.md) — Sprint `1.52`
   landed the host-provider config/detection surface, and Sprint `4.37` landed host-provider ensure
   decisions plus Docker Linux-frame dispatch; everything Docker-inward stays OS-agnostic Linux.
3. One host-owned `prodbox cluster reconcile|delete [--yes|--cascade [--yes]|--allow-pulumi-residue [--yes]]|status|health|wait|start|stop|restart|logs|workload-logs` surface for
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
    rebuild cycles restore the certificate rather than re-ordering it against ZeroSSL), Keycloak
    remains the
    identity provider, every externally reachable app or dashboard lives under the single hostname
    `test.resolvefintech.com`, Envoy enforces Keycloak-backed JWT auth and RBAC on explicit path
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
    `https://test.resolvefintech.com/<service-path>`, with one public DNS record, one public
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
> Production retains EBS (the analog of `.data/`); the test harness deletes only test-scoped EBS at
> suite postflight, closing the EBS-leak class an abnormal AWS bill surfaced. Sprint `4.39` has
> landed the managed-resource registry entry, typed EC2 discover/destroy boundary, retain/test
> scoped tag markers, and retained-inventory parity; Sprint `4.40` has landed the suite postflight
> test-EBS reaper, retain-safe drain guard, cascade hook, and `aws ebs reap-test --yes` recovery
> entrypoint. Sprint `7.28` has landed static EBS PV materialization on the AWS code-owned path
> (CSI renderer, retained EBS ensure loop, AWS chart/bootstrap dispatch, and AZ-pinned node group);
> Sprint `5.12` has landed the code-owned `eks-volume-rebind` validation surface
> (command/planner/body/oracle). The destructive home/AWS live proofs remain non-blocking live-infra
> axes in Sprints `5.12`/`7.28`. The work expands
> each phase's own owned surface (no
> new phase, Standards A/E/N preserved).

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
[README.md → Closure Status](README.md#closure-status) entry (superseding the 2026-06-11 framing for
the derivation model), extended by the 2026-06-13 storage-topology-reorg and the 2026-06-15 Model-B
entries in the same section.

## Test Substrates

Per [development_plan_standards.md → M. Test Suite Substrates](development_plan_standards.md#m-test-suite-substrates),
the canonical test suite is composed of per-substrate runs against both supported substrates.
A substrate is an environment that, for the lifetime of a suite run, stands up the same set of
DNS records, TLS certificates, ingress, services, and workload charts; provides the
prerequisites declared in `src/Prodbox/Prerequisite.hs`; and is torn down on suite exit. The
authoritative substrate inventory is [substrates.md](substrates.md).

Substrate selection is total. Each per-substrate run targets exactly one substrate, consumes
only that substrate's operator-supplied config, and fails fast if any required substrate config
is missing. There is no silent fallback to the other substrate's values. A canonical-suite
proof is complete only when both substrate runs have landed. See
[development_plan_standards.md → M. Substrate coverage and independence (no fallback)](development_plan_standards.md#substrate-coverage-and-independence-no-fallback).

The test harness is the **exclusive owner** of every AWS resource any `prodbox` flow creates
or destroys. The authoritative AWS resource inventory and per-resource lifecycle class
(auto-managed per-run stacks vs long-lived cross-substrate shared infrastructure that is
retained by design) live in
[substrates.md → Resource Lifecycle Classes](substrates.md#resource-lifecycle-classes).

| Substrate | Provision | Teardown | Status authority |
|-----------|-----------|----------|------------------|
| Home local | `prodbox cluster reconcile` + `prodbox charts reconcile ...` | Restore the selected home platform/charts after the run; explicit `prodbox cluster delete --yes` preserves LongLived roots (`--cascade` also destroys per-run AWS stacks) | Current parity and deployment qualification live only in [README.md → Substrate Parity](README.md#substrate-parity) and [Deployment Qualification](README.md#deployment-qualification). |
| AWS | `prodbox aws stack eks reconcile` + `prodbox aws stack aws-subzone reconcile` + `prodbox aws stack test reconcile` | `prodbox aws stack aws-subzone destroy --yes` + `prodbox aws stack eks destroy --yes` + `prodbox aws stack test destroy --yes`; LongLived shared/home resources remain | Current parity and deployment qualification live only in [README.md → Substrate Parity](README.md#substrate-parity) and [Deployment Qualification](README.md#deployment-qualification). |

Phase ownership separates suite content (which lives in
[phase-5-canonical-test-suite.md](phase-5-canonical-test-suite.md)) from substrate
provision/teardown and substrate foundations. No phase may own a substrate-specific validation:
validations are suite content and run against every substrate that satisfies their declared
prerequisites.

## Clean-Room Sequence

The phase order below is the forward **build** order — later phases compose earlier deliverables —
**not** a validation gate. Per the phase-independence doctrine
([development_plan_standards.md → N. Phase Independence](development_plan_standards.md#n-phase-independence-no-backward-blocking)
and [O. Code-Local Completion vs. Live-Infra Proof](development_plan_standards.md#o-code-local-completion-vs-live-infra-proof);
adoption scheduled as Sprint `0.15` in
[phase-0-planning-documentation.md](phase-0-planning-documentation.md)), each phase is validatable
on its owned surface even while any other phase is incomplete, an incomplete later phase never
blocks, gates, or reopens an earlier phase, and the **Independent Validation** column states how
each phase is proven on its owned surface with no dependency on a later phase. Where a validation
would touch a dependency owned by another phase it is exercised against the home/local substrate, a
fake, or a stub; AWS-substrate coverage of suite content is orthogonal and tracked only in
[substrates.md](substrates.md)'s parity table.

| Phase | Focus | Current result | Independent validation |
|-------|-------|----------------|------------------------|
| 0 | Planning and Documentation Topology | ✅ Reclosed on `0.17`: the Foundation Epoch is adopted on top of the `0.16` control-plane correction, Standard P carries the interim escape-path guard, and Sprints `1.61`/`1.62` are shrink-rescoped. Sprint `0.18` adds the configurable certificate-scope governance surface on that same documentation surface (an additional governance sprint, no further reclose). | Documentation lint/check and canonical quality gate; no runtime dependency. |
| 1 | Runtime, CLI, Config, and Pulumi Foundations | ✅ Reclosed on `1.67`: Sprints `1.61`–`1.66` are Done, and generic Kubernetes reachability now follows the selected substrate kubeconfig through `ToolKubectl` + authoritative `kubectl cluster-info` without importing home-local RKE2 file/service prerequisites. | Pure capability-kind, graph, deadline, capacity, object-store protocol, Vault-session, and prerequisite transitive-closure properties. |
| 2 | Gateway Runtime and DNS Ownership | ✅ **Reclosed 2026-08-11 on Sprint `2.42` (Standard A/N)** — the own-surface reopen on the Bootstrap Broker readiness contract this phase owns through Sprints `2.39`/`2.40` is closed. `kubernetesObserveBootstrapLease` discarded its typed transport failure, so a dropped packet, a `403`, and a `404` all reached the operator as one sentence while `/healthz` answered 200. All six discarding sites now carry their detail and `requestKubernetes` classifies the caught exception onto a closed, payload-free label set rather than `show`-ing it, because the request carries a bearer token and the readiness body is operator-visible. Prior reclose on Sprint `2.41` (2026-08-07). ✅ Reclosed on Sprint `2.36` (2026-07-27). Forced drain resolves replay waiters before cancellation, joins persistent cancellation children, and publishes `BrokerStopped` only through an opaque empty-residue witness; deadline observation is `ShutdownIncomplete` while ownership remains represented. | Deterministic finalizer-stall proof, focused loopback suite 6/6, full unit suite except the independently corrected SSH-fixture executable race, and `prodbox dev check`. |
| 3 | Chart Platform and Public Workload Delivery | ✅ **Reclosed 2026-08-11 on Sprint `3.34` (Standard A/N)** — the Kubernetes API egress coordinate has one compiled owner observed from `endpoints/kubernetes` (post-DNAT address and port together), both charts bind it through `.Values`, and the chart-lint region widens to every repo-owned template under a closed port-key set; its first run named 77 findings, reconciling with the 79 measured less the two already migrated. `dev check` 0, `test unit` 0. Validation 5 stays 🧪 Standard-O pending on Sprint `2.43`. Prior state — 🔄 **Reopened 2026-08-10 on Sprint `3.34` (Standard A/N)** — an own-surface reopen on the chart platform and chart lint. The Kubernetes API egress coordinate has no compiled owner, so three sites each author their own `443` while the API endpoint listens on `6443` post-DNAT; `3.34` derives it from `endpoints/kubernetes` and widens the chart lint to every repo-owned template, closing a region in which no gate reads a `networkpolicy.yaml` for content. Edits a live production rendering path. Prior reclose on Sprint `3.33` (2026-08-09). ✅ Reclosed 2026-07-25. Sprint `3.26` renders the physically separated control-plane workloads; `3.28`/`3.29` single-source resource rendering and durable PVC sizes; `3.27` derives namespace admission from validated demand and placement. | Deterministic chart rendering, identity/policy/resource/probe lint, negative topology fixtures, retained-volume plans, unit/integration suites, and `prodbox dev check`. |
| 4 | Lifecycle Hardening and Pulumi Decoupling | ✅ **Reclosed 2026-08-10 on Sprints `4.73`-`4.75`**, ending the own-surface reopen on the condition it existed to remove: no `Pending Removal` row on a Phase-`4` surface is unowned. `4.73` routes the SES DNS writer through the typed `DnsRecordProgram` under its own `LongLived` owner, with a total owner/type matrix, canonical CNAME/MX value forms, and a propagation barrier that keeps the batch's single wait; `4.74` gives the Vault CAS seam the `ModelBCas*`-style vocabulary and a build rule enforcing it, after finding four callers classifying wrongly where the row said none classified at all; `4.75` owns the authored control-plane service time and corrects the haddock that called it measured. Prior reclosures stand. | Pure capacity/admission and deadline folds, the owner/type matrix and CAS classifier as total pure functions, socket-pair proofs of the `429`/`408` replies with no listener, mutation exercises on the `dev check` gates, and the installed `cli` integration suite — no live infrastructure. The live Route 53 read-back and the control-plane measured profile remain Standard-O axes. |
| 5 | Canonical Test Suite | ✅ Reclosed on Sprint `5.31` (2026-08-09). The final fixture drifts are corrected and the installed integration surface is green; clean-room deployment qualification remains pending under Standards O/P. | Installed `cli`/`env` integration **55/55** and canonical `prodbox test unit` exit 0 with main Hspec **3255/3255**, using fake/local proof with no later-phase or live-infrastructure dependency. |
| 6 | Final Clean-Room Rerun and Handoff | ✅ Reclosed on Sprint `6.4` (2026-08-02): exact-prefix cutover/restore/cleanup, rollback refusal, installed-binary plan, and retired-transport absence are validated; destructive aggregates remain qualification. | Focused 8/8, installed command exit 0, unit 3028/3028, generated docs, and `dev check` exit 0. |
| 7 | AWS Substrate Foundations | ✅ Reclosed on Sprint `7.33` (2026-08-02); AWS role/transport isolation, deterministic ownership, target DNS01, public-A Provider intents, and fault dispositions are code-locally complete. | AWS topology rendering/fakes followed by the current-revision AWS isolation and cleanup campaign. |
| 8 | Invited Email Authentication | ✅ Reclosed on Sprint `8.12` (2026-08-02): the durable SES workflow and non-partial invite fault/qualification artifact are code-locally complete; live qualification remains Standards O/P. | Invite 8/8, daemon lifecycle 27/27, unit 3067/3067, installed CLI/environment 55/55 twice, and `prodbox dev check` exit 0. |

## Alignment Status

The per-phase closure state and Independent Validation are the table above. The dated reopen/closure
history is consolidated in [README.md → Closure Status](README.md#closure-status)'s milestone ledger,
and per-sprint detail lives in the phase documents ([phase-0](phase-0-planning-documentation.md) …
[phase-8](phase-8-email-invite-auth.md)) — this section is not a per-sprint changelog (Standard D).

**Current head state (2026-08-10, second entry — every phase is closed):**

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
ledger is unchanged. The dated
adoption entry and live status live in [README.md → Closure Status](README.md#closure-status).

## Architecture Summary

| Surface | Canonical Target Path | Authority |
|---------|-----------------------|-----------|
| CLI control plane | `prodbox <command>` | Haskell executable |
| Host build artifacts | `.build/prodbox` | `cabal build --builddir=.build exe:prodbox` plus copy to `.build/prodbox` |
| Container build artifacts | `/opt/build` via Dockerfiles under `docker/` | Repository-owned Dockerfiles |
| Supported host runtime | `Ubuntu 24.04 LTS` with systemd | `prodbox` supported-host gate |
| Configuration | Binary-sibling Tier-0 `prodbox.dhall` decoded directly into Haskell types through its `parameters` payload, with generated `prodbox-config-types.dhall` / `test-secrets-types.dhall` schemas and no supported `prodbox-config.json` artifact | Executable sibling plus Haskell schema renderer |
| Host diagnostics | `prodbox host ensure-tools|check-ports|info|firewall ...` | Haskell CLI |
| Local RKE2 lifecycle | `prodbox cluster reconcile|delete --yes|status|health|wait|start|stop|restart|logs|workload-logs` | Haskell CLI; reconcile compiles exact capability requirements into component-owned steps. Observation, admission, and execution resolve through the same operation-indexed `CapabilityRef`; delete and suite cleanup use typed always-run obligations rather than a first-failure list. |
| Registry and image reconcile | Single-binary in-cluster `registry:2` with MinIO storage, a bounded storage-bootstrap exception, idempotent public/custom-image population, alternate-source retry, and native-host-architecture publication for the Envoy Gateway edge and chart workloads | Haskell lifecycle runtime |
| Kubernetes utilities | `prodbox cluster health|wait|logs|workload-logs` | Haskell CLI |
| AWS substrate provision/teardown (EKS) | `prodbox aws stack eks reconcile|destroy --yes` | Haskell orchestration plus Pulumi; provisions the `aws-eks` registry stack (Pulumi stack id `aws-eks-test`) for the AWS substrate. The `aws-eks` canonical suite validation runs against it. |
| AWS substrate provision/teardown (Route 53 subzone) | `prodbox aws stack aws-subzone reconcile|destroy --yes` | Haskell orchestration plus Pulumi; provisions the delegated AWS-substrate hosted zone used by public-edge proofs. |
| AWS substrate provision/teardown (HA RKE2) | `prodbox aws stack test reconcile|destroy --yes` | Haskell orchestration plus Pulumi; provisions the EC2 portion of the AWS substrate. The `ha-rke2-aws` canonical suite validation runs against it. |
| Pulumi backend state | Immutable encrypted checkpoint blobs: primary bytes in MinIO `prodbox-state` plus mandatory receipt-committed exact copies at the independent long-lived S3 coordinate, referenced atomically from a versioned Lifecycle Authority record and hydrated only into bounded RAM-backed scratch | Lifecycle Authority plus separate Backup Adapter and fenced provider worker; gateway and host-direct transports have no post-cutover authority |
| Per-run Pulumi state (MinIO-backed; survives cluster wipes via MinIO's PV under `.data/prodbox/minio/0`) | Opaque `objects/<id>.enc` Model-B objects produced by `Prodbox.Pulumi.EncryptedBackend`; first-touch raw checkpoint migration imports legacy backend state before supported writes continue encrypted | Haskell Pulumi orchestration and AWS substrate helpers |
| Gateway-owned secret-derivation MinIO bucket — **retired** | Historical `s3://prodbox?endpoint=127.0.0.1:39000` / `prodbox/master-seed`; the master-seed derivation model is retired (Sprint `3.19`). The pre-cutover gateway generic-object route is also scheduled for deletion; the target Gateway has no MinIO principal. | No target authority; history is retained only in the cleanup ledger |
| Bootstrap Broker | Same-binary dedicated pre-Vault daemon command and internal Service | Sole bounded Vault initialize/unseal/status/rotation boundary; no mesh, lifecycle, provider, or target-secret API |
| Lifecycle Authority | Same-binary retained control-plane daemon and internal Service | Authority epoch/time, operation journal, fences, checkpoint references, provider revisions, credential generations, and delivery outbox |
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
| Leak-proof resource lifecycle | `Prodbox.Lifecycle.ResourceClass`, `Prodbox.Lifecycle.ResourceRegistry`, and typed resource modules such as `Prodbox.Lifecycle.EbsVolume` | Pure data-only registry plus committed desired-absence programs cover every creatable stack, retained/test EBS, controller resource, exact A/TXT record, operational IAM/key, retained bucket/object, and mutating canary. Teardown uses an always-run DAG; `Unobservable` never means absent, and no create-call lint carve-out bypasses registration. Doctrine: [lifecycle_reconciliation_doctrine.md § 3.1](../documents/engineering/lifecycle_reconciliation_doctrine.md). |
| Formal verification | `prodbox dev tla-check` | Haskell CLI invoking the TLA+ toolchain |
| Code quality gate | `prodbox dev check` | Haskell CLI plus governed doctrine-alignment enforcement |
| Status and blockers | `DEVELOPMENT_PLAN/` | This plan suite |

## Current Repository State

The Haskell-only baseline remains implemented, but its gateway-backed lifecycle authority,
nominal deep-readiness target, subprocess object-store path, synchronous retained SES bracket, and
first-failure restore sequence are superseded. Phase `0` is reclosed on the corrected doctrine;
Phases `1`–`8` are reclosed on their expanded code-owned surfaces after the numerical completion
pass through Sprint `8.12`, with Phase `5` most recently reclosed on Sprint `5.31` (2026-08-09).
Installed `cli`/`env` integration passes **55/55**, and canonical `prodbox test unit` exits 0 with
main Hspec **3255/3255**. The live home/AWS aggregate and fault records remain pending only on the
distinct deployment-qualification axis.

Sprints `1.60`, `2.31`, `3.25`, `4.47`, `5.16`, `5.17`, and `8.10` remain complete historical work
for their stated surfaces. They do not qualify the expanded process topology. The supported
operator surface remains `prodbox`; configuration remains direct `Dhall -> Haskell types` rooted at
the binary-sibling Tier-0 `prodbox.dhall`; test-only plaintext remains isolated to
`test-secrets.dhall`; build roots remain `.build/prodbox` and `/opt/build`; and unsupported Python
runtime/tooling surfaces remain removed.
The supported public edge uses MetalLB, Envoy Gateway, Gateway API, cert-manager, and
Keycloak on the single public hostname `test.resolvefintech.com`. Every externally reachable
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

The authoritative lifecycle target uses a single in-cluster `registry:2` with MinIO storage and
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

## Current Execution State

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
local RKE2 file/service facts remain explicit home-local nodes. Phases `3`–`8` retain the Planned,
Active, or forward-only Blocked states in the Alignment Status table, with Sprint `3.26` now
unblocked by the completed `2.33`. Deployment qualification is pending on both substrates. The historical narrative
below remains closure history for earlier work; it is not the current status ledger. Current status is
[Alignment Status](#alignment-status) and
[DEVELOPMENT_PLAN/README.md](README.md#current-plan-status).

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
issuer with S3 retain-and-restore); see the [Alignment Status](#alignment-status) note for the
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
  platform, retained state model,
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
- Phase 4 owns the durable Lifecycle Authority aggregate, operation journal/outbox, immutable
  checkpoint references, target delivery, authority-epoch cutover, in-cluster `registry:2`
  lifecycle hardening, the bounded MinIO/storage bootstrap
  exception, the public AWS-validation Pulumi surface, lifecycle-owned bootstrap DNS
  and ACME projection, Python removal, and the native-host-architecture container-build doctrine.
  The Phase `4` lifecycle bootstraps the registry's MinIO storage, reconciles the single-binary
  registry, and keeps its later AWS-
  validation and Python-removal surfaces closed on the supported path. Sprint 0.4 extends
  Sprint 4.5 with the same forbidden-flag and sister-command discipline on the lifecycle
  reconciler; the one-cycle `install` alias has been retired, and `install`, `upgrade`,
  `repair`, and `force-install` are rejected at parse time.
- Phase 5 owns capability-bound preparation, the always-run cleanup DAG, the temporal
  CPU/queue/deadline/fault oracle, public-edge diagnostics, and external proof on Route 53, Envoy
  Gateway, Gateway
  API, certificate readiness, and external browser validation. It includes API, WebSocket,
  MinIO route classification plus named external proofs for those workloads. Sprint
  `5.5` closes this phase's redirect-only port `80` handling and proof while preserving HTTPS as
  the only application-traffic route.
- Phase 6 owns home-substrate cutover/rollback and prerequisite qualification evidence, the destructive
  clean-room rerun and zero-Python repository handoff criteria, proved through consecutive
  aggregates, always-run postflight restore, `config show`, `config validate`,
  `edge status`, and supported-path repository review gates for placeholder-domain and Python
  residue. Sprint `8.12` is the sole final deployment-qualification owner for both substrates after
  the later shared SES workflow revision.
- Phase 7 owns AWS Broker/Target-Agent/Gateway parity, exact transport to the single retained home
  Lifecycle Authority, and deployment qualification, interactive
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
- Supported public workloads and operational dashboards route only through Envoy on the shared
  hostname `test.resolvefintech.com`. The supported auth doctrine keeps the token carrier
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
- Pulumi remains the exclusive provisioner and destroyer for AWS test resources behind the public
  `prodbox aws stack ...` surface, while bootstrap DNS reconcile and ACME `ClusterIssuer`
  projection remain lifecycle-owned in `src/Prodbox/CLI/Rke2.hs`.
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
- The only supported DNS model is one explicit Route 53 record for `test.resolvefintech.com`;
  wildcard public DNS and per-service public hostnames are not part of the supported
  architecture.
- The supported public workload catalog includes the cluster-backed `vscode` stack, a
  JWT-protected API route, a WebSocket route, and path-routed operational dashboards; none may
  depend on app-local nginx auth proxies or dedicated public subdomains.
- `example.com` must be completely removed from the supported codebase, defaults, fixtures, and
  documented runtime contracts.
- Final handoff requires a destructive rerun from full local delete through final AWS teardown on
  the Haskell stack with no Python implementation dependency.
