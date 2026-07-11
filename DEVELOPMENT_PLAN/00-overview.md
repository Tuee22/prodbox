# prodbox Development Plan - Overview

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md),
[development_plan_standards.md](development_plan_standards.md),
[system-components.md](system-components.md),
[substrates.md](substrates.md),
[phase-0-planning-documentation.md](phase-0-planning-documentation.md),
[phase-1-runtime-cli-aws-foundations.md](phase-1-runtime-cli-aws-foundations.md),
[phase-2-gateway-dns.md](phase-2-gateway-dns.md),
[phase-3-chart-platform-vscode.md](phase-3-chart-platform-vscode.md),
[phase-4-lifecycle-canonical-paths.md](phase-4-lifecycle-canonical-paths.md),
[phase-5-canonical-test-suite.md](phase-5-canonical-test-suite.md),
[phase-6-clean-room-handoff.md](phase-6-clean-room-handoff.md),
[phase-7-aws-substrate-foundations.md](phase-7-aws-substrate-foundations.md),
[phase-8-email-invite-auth.md](phase-8-email-invite-auth.md),
[the engineering doctrine docs](../documents/engineering/README.md),
[vault_doctrine.md](../documents/engineering/vault_doctrine.md)
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
13. One local-cluster-first Pulumi backend model: the local RKE2 cluster runs MinIO and stores AWS
    test-stack state in the generic `prodbox-state` bucket; Sprint `7.14` now routes main Pulumi
    stack cycles and production residue/output reads through the decrypt-to-scratch Model-B
    interposition, including first-touch raw checkpoint migration into the encrypted object-store.
14. One in-cluster Haskell gateway runtime with config generation, bounded semantic ownership
    state, bounded HTTP diagnostics, constant-time `/healthz` and `/readyz`, latest-heartbeat
    projection, DNS-write gating, Orders-backed interval validation, HMAC-signed per-emitter
    sequence state, and bounded cursor/delta peer gossip rather than full-log replication,
    runtime claim/yield emission under the `CanWriteDns` gate,
    operator-verifiable bounded-clock-skew enforcement through the supported-host NTP gate and
    `/v1/state` skew reporting, and atomic Orders-promotion coordination keyed off the monotonic
    `orders_version_utc` field. The same daemon is the post-bootstrap host↔cluster control boundary:
    after the host has deployed the cluster services and the loopback-restricted daemon NodePort,
    root Vault lifecycle requests go through the daemon rather than direct host Vault/MinIO
    transports; Sprint `7.30` finishes the same boundary for object-store-backed Pulumi/residue
    operations.
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
    eviction floors, namespace quotas, every chart container's cpu/memory/ephemeral-storage
    request+limit envelope, and every durable PVC capacity are declared in the typed capacity plan.
    A configuration that over-reserves the host, schedules workloads beyond cluster allocatable
    capacity, or renders an uncapped container is invalid before mutation. Runtime memory is a
    separate nested proof: bounded retained state plus maximum heap scratch fits the RTS heap cap;
    the heap cap plus native/non-heap, serialized child-process, kernel/cgroup, and safety reserves
    fits the container limit. External restart/OOM/high-water observation remains required. See
    [resource_scaling_doctrine.md](../documents/engineering/resource_scaling_doctrine.md).
18. Exactly one preserved operator-host directory: `.data/`. Chart secrets, gateway
    peer-event keys, AWS stack outputs, EKS kubeconfig material, and HA-RKE2 SSH key
    material all live inside the cluster (k8s Secrets fetched from Vault KV via Vault
    Kubernetes auth, or Pulumi stack outputs read on demand). The legacy
    `.prodbox-state/` repo-local cache is removed. In-cluster Vault on its durable PV
    under `.data/vault/vault/0` is the persistence anchor for every secret; its KV store
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
    capabilities control desired presence. Invite-capable suites reconcile `aws-ses` through the
    retained home/control-plane Model-B checkpoint authority, await semantic SES readiness, and
    then materialize SMTP KV into the selected target cluster; ordinary postflight never destroys
    the long-lived stack.

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

> **Runtime-memory correction (2026-07-10).** The July 10 gateway OOM evidence does not invalidate
> those authored-admission and containment lemmas; it invalidates the stronger inference that they
> prove runtime demand. Phases `1`/`2`/`3`/`5` reopened on Sprints `1.60`/`2.31`/`3.25`/`5.16`.
> Sprint `1.60` has reclosed Phase `1` with the nested heap/cgroup budget and generated RTS policy;
> Sprint `2.31` has reclosed Phase `2` with bounded gateway state/transport and credentialed DNS;
> Sprint `3.25` has reclosed Phase `3` with typed/generated constant-time chart probes; Sprint
> `5.16` has landed the external restart/OOM/high-water stability oracle. The longer live stress
> proof remains a non-blocking Standard-O axis, not code-owned work.

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

Vault is the **sole, finalized** secrets / KMS / encryption-as-a-service / PKI root of every
prodbox-managed cluster — there is no transitional or bridge pattern. Every secret, credential, key,
and certificate the stack uses is a Vault object (a KV v2 secret, a Transit key, or a PKI-issued
cert), with no second store and no plaintext fallback; **a sealed (or unreachable / uninitialized)
Vault bricks the cluster** (hard fail-closed). Vault runs in-cluster on a durable `.data/`-backed PV
(`.data/vault/vault/0`), preserved across cluster wipes exactly like MinIO's PV, and is **init-once
/ unseal-on-rebuild** — `vault init` runs exactly once ever (the first time the PV is empty) and
every subsequent `cluster reconcile` only unseals it, so Vault KV is as durable across rebuilds as
any retained PV. The binary-sibling Tier-0 `prodbox.dhall` carries the operator-authored
non-secret parameters and only typed `SecretRef.Vault` references for operational credentials
(never plaintext secrets); the in-force cluster configuration is itself a
Vault-Transit-enveloped MinIO object that is the **config SSoT**. The former filesystem
`prodbox-config.dhall` seed/propose file is retired and survives only as a legacy payload shape for
decode/import/migration tests; every prodbox-owned MinIO object, the Pulumi backend state, and the
active daemon Dhall are
stored only as Vault-Transit envelopes (**Model B**: prodbox's own application-level envelope per
object, not MinIO bucket SSE) through one shared object-store that names objects
`objects/<vault-keyed-HMAC>.enc` under one flat prefix in **one generically-named bucket** (the
role-revealing names `prodbox` + `prodbox-test-pulumi-backends` are retired), keeps a Vault-encrypted
index, hashes the stored AAD (`prodbox-envelope-v2`), and decoy-pads to a constant object count — so
a sealed Vault leaks no information about a cluster's children (existence, count, location, or name);
Pulumi runs through a decrypt-to-scratch RAM-tmpfs interposition (its own secrets provider is
dropped) and the long-lived `aws-ses` backend is enveloped uniformly; and the TLS, Keycloak, Pulumi,
and AWS-credential paths fail closed when Vault is sealed. The master-seed HMAC derivation model and its daemon-only seed boundary are
**retired, not wrapped** — `Prodbox.Secret.{Derive,MasterSeed,Inventory}`, the daemon
`/v1/secret/*` RPC, the daemon-only-seed lint, and `selfBootstrapOwnSecrets` are removed, there is
no `master-seed` object in MinIO, and every previously-derived or chart-generated secret becomes a
Vault KV object fetched via Vault Kubernetes auth; `FileSecret` / Secret-mounted plaintext Dhall is
**removed, not bridged**. The retained `.data/` PV model, the single ZeroSSL ACME issuer + S3
retain-restore (with key material now Vault-protected), and the managed-resource-registry teardown
all stay. Cluster federation adds a **Vault transit-seal trust tree**: a root cluster (Shamir seal,
operator-unsealed via the `.age` unlock bundle) and zero or more child clusters
(`seal "transit"` against the parent), where each parent's Vault KV owns its children's init keys
and a cluster's downstream-cluster inventory is itself secret behind an unsealed Vault — so the
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
checkpoint migration hooks, and Vault-only AWS provider credential resolution through
`secret/gateway/gateway/aws`; the generated operational `aws.*` schema now uses a mandatory
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

| Substrate | Provision | Teardown | Suite parity today |
|-----------|-----------|----------|--------------------|
| Home local | `prodbox cluster reconcile` + `prodbox charts reconcile ...` | `prodbox cluster delete --yes` (`--cascade` also destroys per-run AWS stacks) | 🧪 Code-owned current membership is closed, including bounded gateway runtime, the absorbing stability oracle, desired-present retained-SES preparation, and exact semantic readiness. Prior ZeroSSL/OIDC/WebSocket/public-edge proofs remain historical evidence; a fresh deployed home invite aggregate through the new gate is `Live-proof: pending`. |
| AWS | `prodbox aws stack eks reconcile` + `prodbox aws stack aws-subzone reconcile` + `prodbox aws stack test reconcile` | `prodbox aws stack aws-subzone destroy --yes` + `prodbox aws stack eks destroy --yes` + `prodbox aws stack test destroy --yes` | 🧪 The Phase-7 substrate foundation and then-canonical June slice remain proven, and the July code-owned additions are closed. Fresh AWS identity/DKIM/MX/rule propagation and the deployed AWS invite aggregate are non-blocking `Live-proof: pending` axes. Current validation-by-substrate status lives in [substrates.md](substrates.md). |

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

| Phase | Focus | Closure Result | Independent Validation |
|-------|-------|----------------|------------------------|
| 0 | Planning and Documentation Topology for Haskell Rewrite | The plan suite is rewritten around the Haskell end state | Validated by `prodbox dev lint docs` / `docs check` over the governed plan suite and doctrine docs; no later-phase dependency |
| 1 | Haskell Runtime, CLI, Config, and Pulumi Foundations | ✅ Reclosed on Sprint `1.60`: the opaque nested runtime-memory plan derives its cgroup authority from the workload envelope, validates finite child-schedule evidence, exposes typed scratch/high-water projections, and generates the gateway RTS argv without a Cabal/Docker/Helm heap constant. | Pure constructor tables, the RTS golden, generated chart values, unit 1299/1299, CLI/env integration 45/45, and `prodbox dev check`; no cluster or later phase. |
| 2 | Haskell Gateway Runtime and DNS Ownership | ✅ Reclosed on Sprint `2.31`: bounded semantic state, signed per-emitter sequence/vector-cursor delta/repair gossip, bounded Orders/transport/parser/process-wide allocation, retained continuity, serialized children, and credential/claim/continuity-gated DNS replace the unbounded hot full-log path. | Pure convergence/bound/crash properties, daemon-lifecycle and native partition tests, a profiling build/local heap capture, and `prodbox dev tla-check`; the restart-free live soak remains a non-blocking proof. |
| 3 | Haskell Chart Platform and Public Workload Delivery | ✅ Reclosed on Sprint `3.25`: the gateway chart renders kubelet liveness/readiness from the typed/generated `/healthz` and `/readyz` surface, and chart lint rejects `/v1/state` as a probe. Prior chart/operator closures are preserved. | Warning-clean build, unit 1386/1386, focused probe suite 4/4, generated-values golden/drift check, separate negative fixtures, chart/Haskell lint, Helm rendering, and `prodbox dev check`; no live cluster or later phase. |
| 4 | Lifecycle Hardening, Pulumi Decoupling, and Python Removal | ✅ Reclosed on Sprint `4.47`: the registered desired-present `aws-ses` path composes separate AWS/checkpoint observations with the retained-authority lease, bounded fixed-role STS sessions, fenced encrypted checkpoint, finite SMTP repair, and global target-intent protocol. The fixed role is an `Operational` registered resource and teardown re-observes its absence. | Focused lifecycle/role tables 87/87, warning-clean build, full unit 1476/1476, and `prodbox dev check`; no live AWS or later phase required. |
| 5 | Canonical Test Suite | ✅ Reclosed on Sprints `5.16`/`5.17`: a structured continuous restart/OOM/high-water observer feeds an absorbing run-scoped recorder with a separately restartable healthy window; invite-capable plans now carry one nested target-readiness plus registered retained-SES ensure, while non-invite/postflight plans contain none. | Sprint `5.16`: fake Kubernetes tables 17/17, installed-binary fixtures 2/2, unit 1494/1494, CLI integration 47/47, and `prodbox dev check`. Sprint `5.17`: focused plan/recovery 10/10, target API 6/6, global target-commit 12/12, unit 1508/1508, CLI/env integration 47/47 each, and `prodbox dev check`; live home/AWS runs remain separate proof axes. |
| 6 | Final Clean-Room Rerun and Zero-Python Handoff | The destructive rerun contract closes against every declared substrate in [substrates.md](substrates.md) with no supported Python dependency and no surviving single-host public-edge cleanup in the ledger | Validated locally by `config show`/`config validate`, `edge status`, and the repository review gates for placeholder-domain and Python residue, plus the home-substrate destructive rerun; AWS-substrate rerun coverage is orthogonal (substrates.md parity table) |
| 7 | AWS Substrate Foundations | AWS substrate provisioning/teardown, AWS IAM and quota foundations, interactive onboarding, and the AWS-substrate parity sprint that brings the AWS substrate to canonical-suite parity with the home substrate close on Haskell-only paths; all elevated/admin AWS power enters prodbox through one interactive `SecretRef.Prompt`, and the test-harness-only `test-secrets.dhall` fixture `aws_admin_for_test_simulation.*` simulates that prompt for suite-driven destructive validation, long-lived stack, and `prodbox nuke` flows. **✅ Reclosed 2026-07-10**: Sprint `7.32` compiles the configured AWS DAG through the shared anchored-order engine before mutation, installs final EKS-owned readiness barriers and a scoped gateway Service port-forward across the Vault transition, removes the redundant MinIO reinstall, delegates EKS retry classification to the shared base with no lint allowance, and projects AWS restore from the shared builder after all three stacks (unit 1286/1286; `dev check` exit 0). Live `--substrate aws` is the non-blocking Standard O axis. Prior closure preserved. | Code-owned surface validated locally by `prodbox dev check`, unit tests, and `prodbox test integration cli`/`env` (decrypt-to-scratch wrapper, residue/output reads, credential-class wiring); live AWS proofs are non-blocking Live-proof-pending, no earlier-phase reopen |
| 8 | Operator-Invited Email Authentication via Keycloak + AWS SES | ✅ Reclosed 2026-07-11 on Sprint `8.10`: `Prodbox.Ses.Readiness` classifies exact sender/DKIM/MX/active receipt-rule/action and Pulumi-owned capture-canary list/get semantics, the provider-first transaction polls only `Pending`, and `prodbox host check-ses-readiness` exposes the read-only diagnostic. | Focused readiness 23/23, SES transaction 8/8, lease-role 9/9, built-frontend fixtures 2/2, unit 1535/1535, CLI/env integration 49/49 each, warning-clean build, and Fourmolu check. Fresh AWS propagation and deployed home/AWS invite aggregates are non-blocking live proofs. |

## Alignment Status

The per-phase closure state and Independent Validation are the table above. The dated reopen/closure
history is consolidated in [README.md → Closure Status](README.md#closure-status)'s milestone ledger,
and per-sprint detail lives in the phase documents ([phase-0](phase-0-planning-documentation.md) …
[phase-8](phase-8-email-invite-auth.md)) — this section is not a per-sprint changelog (Standard D).

**Current head state (2026-07-11 — all declared phase-owned code surfaces are closed):**
the July 10 live home canonical-suite run supplied two counterexamples to the previous closure
narrative. All gateway replicas repeatedly hit the exact enforced memory cgroup limit, but
instantaneous Deployment readiness later observed them available; therefore authored capacity and
shallow dependency readiness were incorrectly being treated as runtime-stability proof. Separately,
invite-capable preparation synced from an assumed retained `aws-ses` stack, and SES prerequisites
accepted exit success without proving returned identity/rule state.

The correction is deliberately split by authority: landed Sprint `1.60` owns generic runtime
memory planning; landed Sprint `2.31` owns bounded gateway state/transport and credentialed DNS;
landed Sprint `3.25` owns constant-time chart probes; completed Sprint `4.47` owns the registered
desired-present retained-reconciliation, typed AWS/checkpoint observations, explicit long-lived
checkpoint authority/target sink, gateway CAS, bounded role session, lease, target-intent, and
SMTP-repair transaction; completed `5.16` owns the external gateway
stability oracle; completed `5.17` owns capability-derived retained SES preparation; and completed
`8.10` owns semantic SES readiness. The retained home/control-plane `prodbox-state` plus its Vault keyspace owns the SES
checkpoint and lease; the selected substrate is only the target for SMTP KV materialization.

All previously completed sprint work remains preserved. Phases `6` and `7` stay closed because the
new work does not expand their owned surfaces, per Standard N. The June 26 and June 5–9 live runs
remain historical evidence for their then-implemented paths, not proof of the newly specified
bounded-runtime and clean-state preparation requirements. Current phase status is the table above;
cleanup of superseded paths is owned only by
[legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md).

## Architecture Summary

| Surface | Canonical Target Path | Authority |
|---------|-----------------------|-----------|
| CLI control plane | `prodbox <command>` | Haskell executable |
| Host build artifacts | `.build/prodbox` | `cabal build --builddir=.build exe:prodbox` plus copy to `.build/prodbox` |
| Container build artifacts | `/opt/build` via Dockerfiles under `docker/` | Repository-owned Dockerfiles |
| Supported host runtime | `Ubuntu 24.04 LTS` with systemd | `prodbox` supported-host gate |
| Configuration | Binary-sibling Tier-0 `prodbox.dhall` decoded directly into Haskell types through its `parameters` payload, with generated `prodbox-config-types.dhall` / `test-secrets-types.dhall` schemas and no supported `prodbox-config.json` artifact | Executable sibling plus Haskell schema renderer |
| Host diagnostics | `prodbox host ensure-tools|check-ports|info|firewall ...` | Haskell CLI |
| Local RKE2 lifecycle | `prodbox cluster reconcile|delete --yes|status|health|wait|start|stop|restart|logs|workload-logs` | Haskell CLI; reconcile compiles the validated component DAG into component-owned steps plus an explicit edge tail, carries that order in the Plan payload, and polls one-shot readiness observations within bounded fail-closed barriers before dependants. Delete retains hermetic success reporting and actionable non-zero uninstall summaries. |
| Registry and image reconcile | Single-binary in-cluster `registry:2` with MinIO storage, a bounded storage-bootstrap exception, idempotent public/custom-image population, alternate-source retry, and native-host-architecture publication for the Envoy Gateway edge and chart workloads | Haskell lifecycle runtime |
| Kubernetes utilities | `prodbox cluster health|wait|logs|workload-logs` | Haskell CLI |
| AWS substrate provision/teardown (EKS) | `prodbox aws stack eks reconcile|destroy --yes` | Haskell orchestration plus Pulumi; provisions the `aws-eks` registry stack (Pulumi stack id `aws-eks-test`) for the AWS substrate. The `aws-eks` canonical suite validation runs against it. |
| AWS substrate provision/teardown (Route 53 subzone) | `prodbox aws stack aws-subzone reconcile|destroy --yes` | Haskell orchestration plus Pulumi; provisions the delegated AWS-substrate hosted zone used by public-edge proofs. |
| AWS substrate provision/teardown (HA RKE2) | `prodbox aws stack test reconcile|destroy --yes` | Haskell orchestration plus Pulumi; provisions the EC2 portion of the AWS substrate. The `ha-rke2-aws` canonical suite validation runs against it. |
| Pulumi backend state | MinIO bucket `prodbox-state` on the local cluster; Sprint `7.14` hydrates each stack into a RAM-backed `file://` scratch backend and stores the checkpoint back through the opaque Model-B object store | Local cluster bootstrap plus bounded backend validation, Vault readiness, and encrypted object-store access |
| Per-run Pulumi state (MinIO-backed; survives cluster wipes via MinIO's PV under `.data/prodbox/minio/0`) | Opaque `objects/<id>.enc` Model-B objects produced by `Prodbox.Pulumi.EncryptedBackend`; first-touch raw checkpoint migration imports legacy backend state before supported writes continue encrypted | Haskell Pulumi orchestration and AWS substrate helpers |
| Gateway-owned secret-derivation MinIO bucket — **retired** | Historical `s3://prodbox?endpoint=127.0.0.1:39000` / `prodbox/master-seed`; the master-seed derivation model is retired (Sprint `3.19`) and gateway object-store access now targets the generic `prodbox-state` bucket (Sprint `4.30`) | Gateway daemon (`prodbox-gateway` MinIO principal) |
| Gateway runtime operations | `prodbox gateway start --config <path>|status --config <path>|config-gen <output-path> --node-id <node-id>` | Haskell gateway runtime |
| Public workload runtime | `prodbox workload start --config <path>` | Haskell runtime selected only through the `workload.mode = Api \| Websocket` field of the mounted Dhall config per [config_doctrine.md](../documents/engineering/config_doctrine.md); Sprint `3.14` removed the legacy env-var selector |
| Gateway DNS writes | `dns_write_gate` on home local; `prodbox edge reconcile` on AWS | In-cluster Haskell gateway ownership for the home public record; AWS-substrate Route 53 A records point at the Envoy NLB targets and are reconciled by the explicit edge command |
| DNS check | `prodbox dns check` | Haskell CLI |
| Shared public-edge route catalog | `src/Prodbox/PublicEdge.hs` | Haskell-owned shared-host path catalog and issuer derivation for application and admin routes |
| Chart delivery | `prodbox charts list|status <chart>|reconcile <chart> [--dry-run] [--plan-file <path>]|delete <chart> [--yes] [--dry-run] [--plan-file <path>]` | Haskell chart platform over the supported `gateway`, `keycloak`, `vscode`, `api`, and `websocket` chart surfaces, with `gateway` kept separate from the Envoy public edge and the shared-host browser, API, WebSocket, and admin paths delivered behind Envoy |
| Public-edge diagnostics | `prodbox edge status` | Haskell CLI on a single-host Gateway API and Envoy Gateway doctrine, including path-route classification for app and admin surfaces |
| Public-edge auth model | Envoy-enforced Keycloak JWT auth and RBAC on the shared hostname, with explicit bearer-token carriers, browser return paths, and JWKS metadata ownership | Keycloak issuer plus Envoy policy |
| Public-edge transport boundary | Public listener TLS terminates at Envoy on the supported path; backend HTTP remains the current workload default and backend TLS or mTLS requires later explicit doctrine ownership | Haskell lifecycle plus chart doctrine |
| Optional realtime-state model | Redis-backed shared state for supported WebSocket workloads today and any later explicit external rate-limit service | Haskell chart platform plus application workload doctrine |
| Interactive onboarding | `prodbox config setup` | Haskell CLI plus prompt-driven temporary admin AWS credentials and AWS CLI subprocesses |
| AWS IAM, quota, and EBS maintenance | `prodbox aws policy|setup|teardown|quotas check|quotas request|ebs reap-test --yes` | Haskell CLI plus AWS CLI subprocesses; `aws teardown` carries the Sprint `7.6`/`7.7` `PulumiResiduePolicy` contract (default refuse, `--destroy-pulumi-residue` to destroy live stacks first, `--allow-pulumi-residue` operator-acknowledged orphan escape; mutually exclusive at parse time). `aws setup` auto-detects `AKIA…` vs `ASIA…` access keys to conditionally prompt for the session token (Sprint `7.7`). `aws ebs reap-test --yes` deletes only test-scoped EBS volumes for the canonical AWS EKS test cluster using operational `aws.*` loaded from Vault/config. |
| AWS IAM validation harness | `prodbox test integration aws-iam`, targeted `prodbox test integration <name> --substrate aws` validations, `prodbox test integration all`, `prodbox test all` | Shared Haskell validation harness with idempotent IAM-user and Vault/config cleanup. Sprint `7.6` orphan-safety guards: the harness postflight auto-destroys per-run Pulumi stacks (`aws-eks`, `aws-eks-subzone`, `aws-test`) on success / failure / Ctrl-C when a managed suite may provision them. Sprint `7.10` (2026-05-29): the operational-credential teardown (clearing operational `aws.*` + deleting the operational `prodbox` IAM user) runs **only when the per-run destroy succeeded** (pure `clearOperationalCredsAfterPostflight`); on a per-run destroy failure it is **held** so the orphaned per-run stacks keep the operational creds needed to destroy them on retry. The per-run EKS destroy itself now drains the cluster's AWS-affecting K8s resources before `pulumi destroy` (Sprint `4.23`), closing the May 28/29 `DependencyViolation` root cause. Sprint `7.9` (2026-05-29): the harness postflight teardown (`runAwsIamHarnessTeardown`) no longer refuses on long-lived `aws-ses` residue. The Sprint `7.7` `BypassPerRunResidueOnly` refusal was correct only pre-Sprint-4.10, when `aws-ses` was operationally credentialed; post-4.10 `aws-ses` ops acquire admin power through the interactive `SecretRef.Prompt` (the harness simulating it from the `test-secrets.dhall` fixture `aws_admin_for_test_simulation.*`, not a production-config block), so clearing operational `aws.*` cannot strand it. The postflight now uses `BypassAllResidueForHarnessRefresh`, matching the preflight (Sprint `7.5.c.v.c`), so an `aws-ses`-live run no longer strands the freshly-created operational `prodbox` IAM user. |
| Leak-proof resource lifecycle | `Prodbox.Lifecycle.ResourceClass`, `Prodbox.Lifecycle.ResourceRegistry`, and typed resource modules such as `Prodbox.Lifecycle.EbsVolume` | Typed managed-resource registry — the SSoT for every AWS/cluster resource prodbox can create and how to `discover`/`destroy` it. Teardown (`cluster delete`, `aws teardown`, `nuke`) composes idempotent typed reconcilers with `Unreachable` never silently passing; `prodbox dev check` makes a creatable-but-undiscoverable resource unrepresentable. Sprint `4.39` extends the class table with `aws-ebs-volumes`, typed EC2 `describe-volumes`/`delete-volume`, and retain/test-scoped tag partitioning; Sprint `4.40` adds the test-scoped EBS reaper in suite postflight, `cluster delete --cascade`, and `aws ebs reap-test --yes`, plus the retain-safe `Delete`-only drain guard. Doctrine: [lifecycle_reconciliation_doctrine.md § 3.1](../documents/engineering/lifecycle_reconciliation_doctrine.md). |
| Formal verification | `prodbox dev tla-check` | Haskell CLI invoking the TLA+ toolchain |
| Code quality gate | `prodbox dev check` | Haskell CLI plus governed doctrine-alignment enforcement |
| Status and blockers | `DEVELOPMENT_PLAN/` | This plan suite |

## Current Repository State

The Haskell-only baseline remains implemented, and the bounded-gateway, constant-time chart-probe,
retained-preparation, and exact semantic SES-readiness contracts are now implemented. Phases
`0`–`8` are closed on their owned surfaces, with no `Active`, `Planned`, or `Blocked` phase-owned
sprint. The previous graph-derived reconcile, shallow readiness, Vault-root, Model-B encryption,
chart, cleanup, and substrate foundations remain implemented and were not rolled back by the July
reopen.

There is no remaining declared phase-owned code gap. Sprints `1.60`, `2.31`, `3.25`, `4.47`,
`5.16`, `5.17`, and `8.10` are complete. Fresh AWS identity/DKIM/MX/rule propagation and deployed
home/AWS invite aggregates remain non-blocking `Live-proof: pending` axes. The supported
operator surface remains `prodbox`; configuration remains direct `Dhall -> Haskell types` rooted at
the binary-sibling Tier-0 `prodbox.dhall`; test-only plaintext remains isolated to
`test-secrets.dhall`; build roots remain `.build/prodbox` and `/opt/build`; and the unsupported
Python runtime/tooling surfaces remain removed.
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

Root guidance and the governed public-edge, gateway, chart-platform, registry, SES-readiness, and
testing docs agree on the Haskell-only baseline, the closed code-owned phase surfaces, and the
separate non-blocking live-proof axes.

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
- `src/Prodbox/Aws.hs` owns both the public onboarding flow and the standalone AWS administration
  command family. Elevated/admin AWS power enters through one runtime path — the interactive
  `SecretRef.Prompt` — for `prodbox config setup`, `prodbox aws setup`, the native IAM harness,
  `aws-ses` stack ops, and `prodbox nuke`. The ephemeral prompted credential is held in memory for
  one command, used once to mint the dedicated least-privilege `prodbox` identity, then discarded
  (never written as plaintext to Tier-0 Dhall, never stored in Vault). The test harness automates that
  prompt by feeding the `TestPlaintext` `aws_admin_for_test_simulation.*` fixture from
  `test-secrets.dhall` for suite-driven destructive validation, long-lived stack, and `prodbox nuke`
  flows.
- `src/Prodbox/TestPlan.hs`, `src/Prodbox/TestRunner.hs`, and `src/Prodbox/TestValidation.hs`
  now route `prodbox test integration aws-iam`, targeted
  `prodbox test integration <name> --substrate aws` validations,
  `prodbox test integration all`, and `prodbox test all` through one suite-level Haskell IAM
  harness.
- That shared harness now deletes any pre-existing dedicated `prodbox` IAM user and that user's
  access keys before provisioning, uses any pre-existing `aws.*` only to discover and delete the
  IAM user associated with those credentials, proves STS-federated operational credentials with a
  compact AWS-validation session policy, waits for the dedicated IAM-user credentials to pass STS
  and repeated Route 53 hosted-zone probes, mints the IAM-user operational `aws.*` into Vault KV
  after Vault is unsealed by simulating the elevated-credential prompt from the `test-secrets.dhall`
  fixture `aws_admin_for_test_simulation.*` (cert-manager Route 53 DNS01 credentials do not support
  an STS session-token field), and clears the generated operational `aws.*` from Vault KV before
  returning even when later prerequisites fail.
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

### Interpretation

The supported architecture closes on the Haskell-only clean-room lifecycle, the AWS substrate
`prodbox aws stack ...` surface, the in-cluster `registry:2` doctrine, and the Percona-backed
Patroni application-database path. Compatibility-cleanup history now lives only in
[legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md).

## Haskell-Only Architecture by Surface

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

As of the July 11 Sprint `8.10` closure, all declared phase-owned code surfaces are closed; no
phase-owned sprint is `Active`, `Planned`, or `Blocked`. Fresh AWS propagation and deployed
home/AWS invite aggregates remain non-blocking live-proof axes. The historical narrative below
remains closure history for earlier work; it is not the current status ledger. Current status is
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
- Phase 1 owns the CLI, direct-Dhall config contract, `.build/prodbox` artifact contract, the
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
- Phase 2 owns the gateway runtime, DNS inspection surface, the single-record Route 53 doctrine,
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
- Phase 3 owns the chart platform, retained state model, supported public workload delivery, and
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
- Phase 4 owns in-cluster `registry:2` lifecycle hardening, the bounded MinIO/storage bootstrap
  exception, the public AWS-validation Pulumi surface, lifecycle-owned bootstrap DNS
  and ACME projection, Python removal, and the native-host-architecture container-build doctrine.
  The Phase `4` lifecycle bootstraps the registry's MinIO storage, reconciles the single-binary
  registry, and keeps its later AWS-
  validation and Python-removal surfaces closed on the supported path. Sprint 0.4 extends
  Sprint 4.5 with the same forbidden-flag and sister-command discipline on the lifecycle
  reconciler; the one-cycle `install` alias has been retired, and `install`, `upgrade`,
  `repair`, and `force-install` are rejected at parse time.
- Phase 5 owns public-edge diagnostics and external proof on Route 53, Envoy Gateway, Gateway
  API, certificate readiness, and external browser validation. It includes API, WebSocket,
  MinIO route classification plus named external proofs for those workloads. Sprint
  `5.5` closes this phase's redirect-only port `80` handling and proof while preserving HTTPS as
  the only application-traffic route.
- Phase 6 owns the destructive clean-room rerun and zero-Python repository handoff criteria,
  closed through the aggregate rerun, postflight restore, `config show`, `config validate`,
  `edge status`, and supported-path repository review gates for placeholder-domain and Python
  residue.
- Phase 7 owns interactive onboarding, IAM automation, quota management, and the temporary-admin
  credential proof harness on one canonical public hostname with no placeholder-domain residue.

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
- The executable-sibling Tier-0 `prodbox.dhall` is the supported host configuration source and
  sealed-Vault bootstrap floor; once established, the in-force config SSoT is the
  Vault-Transit-enveloped MinIO object.
- The supported configuration handoff is direct `Dhall -> Haskell types`; no supported command or
  validation path may create `prodbox-config.json`, and `prodbox config compile` is not part of
  the target command surface.
- There is exactly one runtime path by which elevated/admin AWS power enters prodbox: the
  interactive `SecretRef.Prompt`. `prodbox config setup`, `prodbox aws ...`, the native IAM
  harness, `aws-ses` stack ops, and `prodbox nuke` all prompt the operator for one ephemeral
  elevated credential set, hold it in memory for one command, use it once to mint the dedicated
  least-privilege `prodbox` identity, then discard it — it is never written to
  `prodbox.dhall`, never stored in Vault, never persisted to disk.
- Stored admin credentials are disallowed in `prodbox.dhall`; there is no production
  config-backed admin path. The only admin credential outside the prompt is the test-harness-only
  `TestPlaintext` fixture `aws_admin_for_test_simulation.*`, which lives in `test-secrets.dhall`
  (never imported by `prodbox.dhall`, never read by a production binary, never in Vault) and
  whose sole purpose is to simulate the interactive prompt so the suite can drive admin-credentialed
  flows non-interactively. See
  [vault_doctrine.md §§3/4/13](../documents/engineering/vault_doctrine.md) for the `SecretRef`
  model, config split, and classification.
- The named and aggregate IAM validation surfaces share one joint idempotent harness that deletes
  any pre-existing dedicated `prodbox` IAM user and all of that user's access keys before
  provisioning, uses any pre-existing `aws.*` only to discover and delete the IAM user associated
  with those credentials, proves STS-federated operational credentials with a compact
  AWS-validation session policy, waits for the dedicated IAM-user credentials to pass STS and
  repeated Route 53 hosted-zone probes, mints the IAM-user operational `aws.*` into Vault KV (after
  Vault is unsealed) by simulating the interactive elevated-credential prompt from the
  `test-secrets.dhall` fixture `aws_admin_for_test_simulation.*` (cert-manager Route 53 DNS01
  credentials do not support an STS session-token field), and clears the generated operational
  `aws.*` from Vault KV before returning.
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
