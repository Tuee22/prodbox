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
9. One Harbor-first steady-state registry doctrine: direct public-registry pulls are permitted
   only for Harbor and Harbor's storage backend during bootstrap, and every later supported Helm
   deployment pulls from Harbor.
10. One idempotent post-bootstrap image-reconcile path: after Harbor is healthy and externally
    serving, `prodbox` ensures required public images and all custom images are present in Harbor
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
14. One in-cluster Haskell gateway runtime with config generation, bounded HTTP `/v1/state`
    observability, heartbeat recording, in-memory ownership projection, DNS-write gating,
    Orders-backed interval validation, HMAC-signed event state, peer-transport gossip with
    commit-log replication, runtime claim/yield emission under the `CanWriteDns` gate,
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
    capacity, or renders an uncapped container is invalid before mutation. See
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
    JWT-protected API route, a WebSocket route, and path-routed operational dashboards such as
    Harbor and MinIO, all on the same public hostname.
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
provider credential migration remains Sprint `7.14`; ACME EAB/TLS key material remains Sprint
`7.15`. Phase `3` has reclosed on its owned surfaces: it has the Sprint `3.17` Vault
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
| Home local | `prodbox cluster reconcile` + `prodbox charts reconcile ...` | `prodbox cluster delete --yes` (`--cascade` also destroys per-run AWS stacks) | ✅ Full canonical suite, including real ZeroSSL, OIDC, WebSocket, and public-edge proofs on `test.resolvefintech.com` |
| AWS | `prodbox aws stack eks reconcile` + `prodbox aws stack aws-subzone reconcile` + `prodbox aws stack test reconcile` | `prodbox aws stack aws-subzone destroy --yes` + `prodbox aws stack eks destroy --yes` + `prodbox aws stack test destroy --yes` | ✅ Phase 7-owned AWS substrate parity was proved live for the then-canonical AWS slice on June 5-9, 2026, including public DNS, chart validations, admin routes, `keycloak-invite`, destructive lifecycle, and postflight teardown. Current canonical-suite membership is defined in `src/Prodbox/TestPlan.hs`; any AWS live proofs for later-added validations are tracked only in [substrates.md](substrates.md)'s per-validation coverage table as non-blocking Standard O axes. |

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
| 1 | Haskell Runtime, CLI, Config, and Pulumi Foundations | One supported Haskell binary owns CLI, config, lifecycle, test, and AWS substrate provisioning foundations. **✅ Reclosed 2026-07-10** after Sprints `1.57`–`1.59`: the final sprint adds the flat readiness observation/result ADTs, typed targets with injected one-shot actions, exhaustive probe dispatch, immediate mismatch refusal, and bounded pending/unreachable waits. The graph records `ProbeServiceActive`, daemon-mediated Vault-unseal ordering, and gateway-full's MinIO `BackendWriteEdge` (`config generate`/`config validate` exit 0, unit 1259/1259, `dev check` 0). Its downstream bindings landed in `3.24`/`4.45`/`5.15`/`7.32`, and no later phase is required to validate Phase `1`. | Validated locally by `prodbox dev check`, `prodbox test unit`, and config generation/validation on its owned CLI/config/readiness surface; no later-phase dependency |
| 2 | Haskell Gateway Runtime and DNS Ownership | Gateway runtime, formal verification entrypoint, Harbor-backed gateway packaging, and the single-record Route 53 ownership contract close on the Haskell stack under the same `ubuntu:24.04` plus `ghcup` toolchain doctrine. **✅ Reclosed 2026-07-10** after Sprint `2.30`: `VaultRoleGatewayDaemon` single-sources the supported `ChartPlatform`-generated gateway `vault.role` and `defaultVaultReconcilePlan` role name (`prodbox-gateway-daemon`), whose policy set is exactly `prodbox-gateway` + `gateway-gateway`; static chart defaults and other gateway configuration surfaces are not claimed (unit 1260/1260, `dev check` 0). | Validated locally by `prodbox dev tla-check`, daemon-lifecycle/`gateway-partition` unit and integration stanzas, `/v1/state` golden tests, and the Sprint `2.30` values/role/policy unit assertions; DNS writes exercised against the home substrate, no later-phase dependency |
| 3 | Haskell Chart Platform and Public Workload Delivery | Chart orchestration, retained storage, Harbor-backed browser/API/WebSocket delivery, path-routed admin delivery, Keycloak-backed Envoy auth and RBAC, Redis-backed realtime state, and the Percona-operator-backed Patroni PostgreSQL doctrine close on the Haskell stack. **✅ Reclosed 2026-07-10** after Sprint `3.24`: the exhaustive `operatorAvailableTarget` registry binds the Percona one-shot `Available=True` observation through `ReadinessObservation`, and only `ReadyObserved` opens mutation. New `ComponentId` constructors require a compile-time decision; an existing config-driven ID without a target fails closed at runtime (unit 1266/1266, chart lint 0, `dev check` 0). Prior closure preserved. | Validated locally by `prodbox dev lint chart`, chart-platform unit tests, and the home-substrate chart deploy/delete path; AWS-substrate chart coverage is orthogonal (substrates.md parity table), no later-phase dependency |
| 4 | Lifecycle Hardening, Pulumi Decoupling, and Python Removal | Home substrate lifecycle parity closes, Harbor bootstrap narrows to Harbor plus its storage backend, bootstrap DNS or certificate issuance collapse to the one-host doctrine, broad local-cluster Pulumi ownership is removed, and Python residue is removed. **✅ Reclosed 2026-07-10**: the typed registry backend/redirect policy landed in `4.44`; `4.45` compiles the validated home RKE2 DAG into `concatMap stepsForComponent (componentReconcileOrder dag)` plus a separate edge tail, with corrected dependencies, total anchors/actions, first-class MetalLB/Envoy Gateway/Percona steps, and a structured fail-closed guard carrying the validated DAG/order in `NativeInstallPayload`. Production readiness targets poll caller-injected one-shot observations within bounds and require each final component barrier before dependants. Sprint `4.46` delegates the Route 53, Helm, and Harbor classifiers to the shared transient base, so Helm inherits the common DNS/transport cases and no RKE2 transitional lint allowance remains (unit 1276/1276; `dev check` exit 0). Prior closure preserved. | Validated locally by `prodbox dev check` (registry ↔ doc parity, create-site coverage), unit tests, config schema generation/validation, and the real home-substrate reconcile dry-run; live-infra proofs are non-blocking Live-proof-pending, no later-phase dependency |
| 5 | Canonical Test Suite | The substrate-agnostic named validation set in `src/Prodbox/TestValidation.hs` closes on one canonical suite with explicit prerequisites; suite content includes public-edge proofs (real TLS, OIDC, WebSocket) that run against whichever substrate is active. **✅ Reclosed 2026-07-10** after Sprint `5.15`: `Prodbox.TestRestore` builds one pure substrate-aware restore plan consumed by bootstrap and postflight, with their core sequences differing only by the typed optional SMTP step. SMTP sync is gated by the shared bounded backend-round-trip observation and returns a structured loopback-endpoint refusal without starting sync when the daemon is pending or unreachable (unit 1280/1280; CLI integration 44/44; `dev check` exit 0). | Each named validation is `Done` when it exists and passes on the home substrate (with fakes/stubs for missing prerequisites); AWS-substrate coverage is orthogonal. The home restore-cycle live proof and AWS aggregate remain non-blocking Standard O axes and never mark this phase Blocked. |
| 6 | Final Clean-Room Rerun and Zero-Python Handoff | The destructive rerun contract closes against every declared substrate in [substrates.md](substrates.md) with no supported Python dependency and no surviving single-host public-edge cleanup in the ledger | Validated locally by `config show`/`config validate`, `host public-edge`, and the repository review gates for placeholder-domain and Python residue, plus the home-substrate destructive rerun; AWS-substrate rerun coverage is orthogonal (substrates.md parity table) |
| 7 | AWS Substrate Foundations | AWS substrate provisioning/teardown, AWS IAM and quota foundations, interactive onboarding, and the AWS-substrate parity sprint that brings the AWS substrate to canonical-suite parity with the home substrate close on Haskell-only paths; all elevated/admin AWS power enters prodbox through one interactive `SecretRef.Prompt`, and the test-harness-only `test-secrets.dhall` fixture `aws_admin_for_test_simulation.*` simulates that prompt for suite-driven destructive validation, long-lived stack, and `prodbox nuke` flows. **✅ Reclosed 2026-07-10**: Sprint `7.32` compiles the configured AWS DAG through the shared anchored-order engine before mutation, installs final EKS-owned readiness barriers and a scoped gateway Service port-forward across the Vault transition, removes the redundant MinIO reinstall, delegates EKS retry classification to the shared base with no lint allowance, and projects AWS restore from the shared builder after all three stacks (unit 1286/1286; `dev check` exit 0). Live `--substrate aws` is the non-blocking Standard O axis. Prior closure preserved. | Code-owned surface validated locally by `prodbox dev check`, unit tests, and `prodbox test integration cli`/`env` (decrypt-to-scratch wrapper, residue/output reads, credential-class wiring); live AWS proofs are non-blocking Live-proof-pending, no earlier-phase reopen |
| 8 | Operator-Invited Email Authentication via Keycloak + AWS SES | Keycloak switches to operator-invited, email-verified auth via AWS SES; shared SES infrastructure (sending identity, receive subdomain, S3 capture bucket) is provisioned cross-substrate; `prodbox users invite|list|revoke` joins the public command surface; `ValidationKeycloakInvite` joins the canonical suite and runs against every substrate | Validated locally by unit tests over the invite/OIDC-claim/SMTP-sync logic and the home-substrate `keycloak-invite` proof; AWS-substrate `keycloak-invite` coverage is orthogonal (substrates.md parity table) |

## Alignment Status

The per-phase closure state and Independent Validation are the table above. The dated reopen/closure
history is consolidated in [README.md → Closure Status](README.md#closure-status)'s milestone ledger,
and per-sprint detail lives in the phase documents ([phase-0](phase-0-planning-documentation.md) …
[phase-8](phase-8-email-invite-auth.md)) — this section is not a per-sprint changelog (Standard D).

**Current head state (2026-07-10 — every phase is Done/Reclosed on its code-owned surface):** Sprints `1.56`,
`3.23`, `4.43`, and `7.31` landed the component/readiness-graph, graph-sourced chart edges, shared
step narration, and deep registry→MinIO foundations. Sprint `4.45` now closes their home RKE2
order/execution projection: the validated DAG drives
`concatMap stepsForComponent (componentReconcileOrder dag)`, while edge reconciliation remains an
explicit separate tail. `buildNativeInstallExecutionPlan` rejects an invalid dependency or phase
projection with a structured error and carries the validated DAG/order in `NativeInstallPayload`
for apply. The default graph declares the registry and post-Vault dependencies consumed by
cert-manager, the pre-Vault gateway, MetalLB, Envoy Gateway, and Percona; every step anchor and
phase action match is total; and the formerly nested three-platform sequence is represented by
first-class MetalLB, Envoy Gateway, and Percona steps. Production readiness targets poll their
caller-injected one-shot observations within bounded fail-closed waits and require each component's
final anchored barrier before dependants execute. The reconcile goldens intentionally expose the
three platform steps and omit the redundant home MinIO steady-state narration (config schema
regeneration and validation exit 0, unit 1273/1273, real `cluster reconcile --dry-run` exit 0,
`dev check` 0).

Sprints `1.57`–`1.59` are ✅ Done and Phase `1` is reclosed; their production bindings landed in
`3.24`/`4.45`/`5.15`/`7.32`. Sprint `2.30` is ✅
Done and Phase `2` is reclosed: `VaultRoleGatewayDaemon` supplies the supported generated gateway
role name and its exact policies. Sprint `3.24` is ✅ Done and Phase `3` is reclosed: its exhaustive
operator-target registry routes Percona's one-shot `Available=True` observation through bounded
`ReadinessObservation` polling, and only `ReadyObserved` opens mutation. Sprint `4.44` is ✅ Done:
`RegistryStorageBackend` and its required `RedirectPolicy` feed the existing renderer without
changing resource ownership. Sprint `4.46` is ✅ Done and Phase `4` is reclosed: the Route 53, Helm,
and Harbor classifiers delegate to the shared transient base, Helm inherits the shared DNS and
transport cases, and the three RKE2 lint allowances are gone (unit 1276/1276; `dev check` exit 0).
Sprint `5.15` is ✅ Done and Phase `5` is reclosed: both restore paths interpret one
substrate-aware typed plan, and the optional SMTP step is gated by the bounded gateway object-store
precondition (unit 1280/1280; CLI integration 44/44; `dev check` exit 0). Sprint `7.32` is ✅ Done
and Phase `7` is reclosed with the shared graph compiler/executor, final EKS-owned readiness
targets, scoped gateway port-forward, shared EKS classifier, and shared AWS restore projection
(unit 1286/1286; `dev check` exit 0). The home restore-cycle live proof remains non-blocking. The
home-substrate aggregate `prodbox test all` is green (2026-06-26, 18/18 validations + both cabal
suites); the live `prodbox test all --substrate aws` aggregate past the EKS image-mirror step is the
non-blocking Standard O live-proof axis ([substrates.md](substrates.md)).

## Architecture Summary

| Surface | Canonical Target Path | Authority |
|---------|-----------------------|-----------|
| CLI control plane | `prodbox <command>` | Haskell executable |
| Host build artifacts | `.build/prodbox` | `cabal build --builddir=.build exe:prodbox` plus copy to `.build/prodbox` |
| Container build artifacts | `/opt/build` via Dockerfiles under `docker/` | Repository-owned Dockerfiles |
| Supported host runtime | `Ubuntu 24.04 LTS` with systemd | `prodbox` supported-host gate |
| Configuration | Binary-sibling Tier-0 `prodbox.dhall` decoded directly into Haskell types through its `parameters` payload, with generated `prodbox-config-types.dhall` / `test-secrets-types.dhall` schemas and no supported `prodbox-config.json` artifact | Executable sibling plus Haskell schema renderer |
| Host diagnostics | `prodbox host ensure-tools|check-ports|info|firewall|public-edge` | Haskell CLI |
| Local RKE2 lifecycle | `prodbox cluster reconcile|delete --yes|status|health|wait|start|stop|restart|logs|workload-logs` | Haskell CLI; reconcile compiles the validated component DAG into component-owned steps plus an explicit edge tail, carries that order in the Plan payload, and polls one-shot readiness observations within bounded fail-closed barriers before dependants. Delete retains hermetic success reporting and actionable non-zero uninstall summaries. |
| Registry and image reconcile | Harbor-first steady-state image sourcing with a Harbor-plus-storage-backend bootstrap exception only, plus idempotent post-bootstrap public-image populate with alternate-source retry and native-host-architecture image publication for the Envoy Gateway target edge and chart workloads | Haskell lifecycle runtime |
| Kubernetes utilities | `prodbox cluster health|wait|logs|workload-logs` | Haskell CLI |
| AWS substrate provision/teardown (EKS) | `prodbox aws stack eks reconcile|destroy --yes` | Haskell orchestration plus Pulumi; provisions the `aws-eks` registry stack (Pulumi stack id `aws-eks-test`) for the AWS substrate. The `aws-eks` canonical suite validation runs against it. |
| AWS substrate provision/teardown (Route 53 subzone) | `prodbox aws stack aws-subzone reconcile|destroy --yes` | Haskell orchestration plus Pulumi; provisions the delegated AWS-substrate hosted zone used by public-edge proofs. |
| AWS substrate provision/teardown (HA RKE2) | `prodbox aws stack test reconcile|destroy --yes` | Haskell orchestration plus Pulumi; provisions the EC2 portion of the AWS substrate. The `ha-rke2-aws` canonical suite validation runs against it. |
| Pulumi backend state | MinIO bucket `prodbox-state` on the local cluster; Sprint `7.14` hydrates each stack into a RAM-backed `file://` scratch backend and stores the checkpoint back through the opaque Model-B object store | Local cluster bootstrap plus bounded backend validation, Vault readiness, and encrypted object-store access |
| Per-run Pulumi state (MinIO-backed; survives cluster wipes via MinIO's PV under `.data/prodbox/minio/0`) | Opaque `objects/<id>.enc` Model-B objects produced by `Prodbox.Pulumi.EncryptedBackend`; first-touch raw checkpoint migration imports legacy backend state before supported writes continue encrypted | Haskell Pulumi orchestration and AWS substrate helpers |
| Gateway-owned secret-derivation MinIO bucket — **retired** | Historical `s3://prodbox?endpoint=127.0.0.1:39000` / `prodbox/master-seed`; the master-seed derivation model is retired (Sprint `3.19`) and gateway object-store access now targets the generic `prodbox-state` bucket (Sprint `4.30`) | Gateway daemon (`prodbox-gateway` MinIO principal) |
| Gateway runtime operations | `prodbox gateway start --config <path>|status --config <path>|config-gen <output-path> --node-id <node-id>` | Haskell gateway runtime |
| Public workload runtime | `prodbox workload start --config <path>` | Haskell runtime selected through the `workload.mode = Api \| Websocket` field of the mounted Dhall config per [config_doctrine.md](../documents/engineering/config_doctrine.md) (migration from `PRODBOX_WORKLOAD_MODE` env-var scheduled by Sprint 3.14) for the supported path-routed API and real-WebSocket surfaces behind the shared public hostname |
| Gateway DNS writes | `dns_write_gate` on home local; host-side public-edge reconciliation on AWS | In-cluster Haskell gateway ownership for the home public record; AWS-substrate Route 53 A records point at the Envoy NLB targets and are reconciled by `prodbox host public-edge --substrate aws` |
| DNS check | `prodbox dns check` | Haskell CLI |
| Shared public-edge route catalog | `src/Prodbox/PublicEdge.hs` | Haskell-owned shared-host path catalog and issuer derivation for application and admin routes |
| Chart delivery | `prodbox charts list|status <chart>|reconcile <chart> [--dry-run] [--plan-file <path>]|delete <chart> [--yes] [--dry-run] [--plan-file <path>]` | Haskell chart platform over the supported `gateway`, `keycloak`, `vscode`, `api`, and `websocket` chart surfaces, with `gateway` kept separate from the Envoy public edge and the shared-host browser, API, WebSocket, and admin paths delivered behind Envoy |
| Public-edge diagnostics | `prodbox host public-edge` | Haskell CLI on a single-host Gateway API and Envoy Gateway doctrine, including path-route classification for app and admin surfaces |
| Public-edge auth model | Envoy-enforced Keycloak JWT auth and RBAC on the shared hostname, with explicit bearer-token carriers, browser return paths, and JWKS metadata ownership | Keycloak issuer plus Envoy policy |
| Public-edge transport boundary | Public listener TLS terminates at Envoy on the supported path; backend HTTP remains the current workload default and backend TLS or mTLS requires later explicit doctrine ownership | Haskell lifecycle plus chart doctrine |
| Optional realtime-state model | Redis-backed shared state for supported WebSocket workloads today and any later explicit external rate-limit service | Haskell chart platform plus application workload doctrine |
| Interactive onboarding | `prodbox config setup` | Haskell CLI plus prompt-driven temporary admin AWS credentials and AWS CLI subprocesses |
| AWS IAM, quota, and EBS maintenance | `prodbox aws policy|setup|teardown|quotas check|quotas request|ebs reap-test --yes` | Haskell CLI plus AWS CLI subprocesses; `aws teardown` carries the Sprint `7.6`/`7.7` `PulumiResiduePolicy` contract (default refuse, `--destroy-pulumi-residue` to destroy live stacks first, `--allow-pulumi-residue` operator-acknowledged orphan escape; mutually exclusive at parse time). `aws setup` auto-detects `AKIA…` vs `ASIA…` access keys to conditionally prompt for the session token (Sprint `7.7`). `aws ebs reap-test --yes` deletes only test-scoped EBS volumes for the canonical AWS EKS test cluster using operational `aws.*` loaded from Vault/config. |
| AWS IAM validation harness | `prodbox test integration aws-iam`, targeted `prodbox test integration <name> --substrate aws` validations, `prodbox test integration all`, `prodbox test all` | Shared Haskell validation harness with idempotent IAM-user and Vault/config cleanup. Sprint `7.6` orphan-safety guards: the harness postflight auto-destroys per-run Pulumi stacks (`aws-eks`, `aws-eks-subzone`, `aws-test`) on success / failure / Ctrl-C when a managed suite may provision them. Sprint `7.10` (2026-05-29): the operational-credential teardown (clearing operational `aws.*` + deleting the operational `prodbox` IAM user) runs **only when the per-run destroy succeeded** (pure `clearOperationalCredsAfterPostflight`); on a per-run destroy failure it is **held** so the orphaned per-run stacks keep the operational creds needed to destroy them on retry. The per-run EKS destroy itself now drains the cluster's AWS-affecting K8s resources before `pulumi destroy` (Sprint `4.23`), closing the May 28/29 `DependencyViolation` root cause. Sprint `7.9` (2026-05-29): the harness postflight teardown (`runAwsIamHarnessTeardown`) no longer refuses on long-lived `aws-ses` residue. The Sprint `7.7` `BypassPerRunResidueOnly` refusal was correct only pre-Sprint-4.10, when `aws-ses` was operationally credentialed; post-4.10 `aws-ses` ops acquire admin power through the interactive `SecretRef.Prompt` (the harness simulating it from the `test-secrets.dhall` fixture `aws_admin_for_test_simulation.*`, not a production-config block), so clearing operational `aws.*` cannot strand it. The postflight now uses `BypassAllResidueForHarnessRefresh`, matching the preflight (Sprint `7.5.c.v.c`), so an `aws-ses`-live run no longer strands the freshly-created operational `prodbox` IAM user. |
| Leak-proof resource lifecycle | `Prodbox.Lifecycle.ResourceClass`, `Prodbox.Lifecycle.ResourceRegistry`, and typed resource modules such as `Prodbox.Lifecycle.EbsVolume` | Typed managed-resource registry — the SSoT for every AWS/cluster resource prodbox can create and how to `discover`/`destroy` it. Teardown (`rke2 delete`, `aws teardown`, `nuke`) composes idempotent typed reconcilers with `Unreachable` never silently passing; `check-code` makes a creatable-but-undiscoverable resource unrepresentable. Sprint `4.39` extends the class table with `aws-ebs-volumes`, typed EC2 `describe-volumes`/`delete-volume`, and retain/test-scoped tag partitioning; Sprint `4.40` adds the test-scoped EBS reaper in suite postflight, `cluster delete --cascade`, and `aws ebs reap-test --yes`, plus the retain-safe `Delete`-only drain guard. Doctrine: [lifecycle_reconciliation_doctrine.md § 3.1](../documents/engineering/lifecycle_reconciliation_doctrine.md). |
| Formal verification | `prodbox dev tla-check` | Haskell CLI invoking the TLA+ toolchain |
| Code quality gate | `prodbox dev check` | Haskell CLI plus governed doctrine-alignment enforcement |
| Status and blockers | `DEVELOPMENT_PLAN/` | This plan suite |

## Current Repository State

The target Haskell-only rewrite baseline is implemented in the worktree, and every phase is
Done/Reclosed on its code-owned surface. Phases `1`/`2`/`3` reclosed after
Sprints `1.57`–`1.59`, `2.30`, and `3.24`, respectively. Sprint `4.44` is Done without changing
resource ownership; Sprint `4.45` is Done with the graph-derived, fail-closed home reconcile plan
and bounded production readiness bindings. Sprint `4.46` delegates every RKE2 retry classifier to
the shared transient base and removes the RKE2 lint allowances, reclosing Phase `4` (unit 1276/1276;
`dev check` exit 0). Sprint `5.15` single-sources the substrate-aware restore plan and gates SMTP
behind bounded daemon object-store readiness, reclosing Phase `5` (unit 1280/1280; CLI integration
44/44; `dev check` exit 0). Sprint `7.32` completes the AWS anchored-step/readiness, shared
classifier, scoped port-forward, and shared restore bindings, reclosing Phase `7` (unit 1286/1286;
`dev check` exit 0). Current worktree evidence puts completed
phase-owned implementation rows in `Done` or `Live-proof pending` state according to
[development_plan_standards.md](development_plan_standards.md) Standards N/O; substrate-specific
AWS live axes for later-added validations are tracked in [substrates.md](substrates.md), not as
phase blockers. The supported operator surface is `prodbox`, the supported configuration contract
is direct `Dhall -> Haskell types` rooted at the binary-sibling Tier-0 `prodbox.dhall` (with
`test-secrets.dhall` reserved for test-only plaintext fixtures), and the supported build topology
remains `.build/prodbox` on the host plus `/opt/build` inside repository-owned Dockerfiles.
`prodbox dev check` enforces the current
governed doctrine-alignment gate, the Haskell gateway runtime plus status path close on the
implemented bounded HTTP `/v1/state` payload and daemon timing-validation contract, the final
clean-room handoff closes on the canonical rerun surface, and the earlier unsupported Python
runtime and tooling surfaces remain removed.

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

Root guidance and the governed public-edge, gateway, chart-platform, registry, and testing docs
agree on the reclosed Haskell-only baseline and the doctrine-adoption surfaces now present in the
tree, including the service, retry, state-machine, output-option, application-environment, daemon
lifecycle, style-tool, and retained Pulumi harness work.

The authoritative lifecycle target remains Harbor-first and native-architecture only: Harbor plus
its storage backend bootstrap from public registries, every later Helm deployment pulls through
Harbor, and `amd64` or `arm64` hosts build and publish only their own architecture. The stack
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
- `src/Prodbox/CLI/Rke2.hs` owns the Harbor-first lifecycle, readiness gates, Harbor population,
  post-bootstrap Harbor-backed workload reconcile, native-host-architecture custom-image
  publication, and alternate-source retry during Harbor mirror publication, including
  `mirror.gcr.io` fallbacks for the Docker Hub-hosted Percona and Envoy images used by the
  supported lifecycle. The current lifecycle installs Envoy Gateway and the Harbor-backed Envoy
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
  repo-backed Pulumi backend on a bounded `pulumi login ... --non-interactive` path and repair a
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
- `src/Prodbox/Gateway.hs`, `src/Prodbox/Gateway/Daemon.hs`, `src/Prodbox/Gateway/Peer.hs`, and
  `src/Prodbox/Gateway/Types.hs` own the current Haskell gateway surface, including the HTTP
  `/v1/state` payload with total `event_count`, a bounded recent `event_hashes` tail,
  `heartbeat_age_seconds`, `peer_transport`, `can_write_dns`, `node_disposition`,
  `peer_dispositions`, `max_clock_skew_seconds_observed`, `max_clock_skew_seconds_bound`,
  `orders_version_utc`, and `latest_observed_orders_version_utc`, plus Orders-backed interval
  validation. The certificate, key, CA, and socket metadata in `DaemonConfig` and `Orders` are
  materialized at runtime through `peerListenerLoop` and
  `peerDialerLoop`, which replicate the append-only commit log between nodes, update
  `stateLastHeartbeatTimes` from inbound peer events, refuse heartbeats outside the configured
  skew bound, and reject inbound batches that present an older Orders version.
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
`prodbox aws stack ...` surface, the Harbor-first registry doctrine, and the Percona-backed
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
the two-issuer model these sprints first added was reverted 2026-06-07); Phase `8` stays open for
Sprints `8.7`/`8.8` (and the live `8.5`/`8.6` proofs).

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
  and the TLA+ validation entrypoint. The Phase `2` gateway surfaces close on the bounded HTTP
  `/v1/state` payload, a distinct native `gateway-partition` validation path, peer-transport
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
  readiness-based drain, and path-routed Harbor plus MinIO admin delivery. The Phase `3`
  doctrine-adoption reopen has closed across Sprints 3.8–3.12, including smart constructors
  for paired chart resources, capability classes on chart Redis and Postgres call sites,
  reconciler discipline on `prodbox charts reconcile` / `delete`, `--dry-run` on chart operations, the
  `prodbox dev lint chart` Helm-chart structural-invariants linter in Sprint 3.12, and
  marker-delimited route-inventory generation from `src/Prodbox/PublicEdge.hs` into chart
  artifacts via the `generatedSectionRule` registry. Sprint 0.4 extends Sprint 3.10 with
  the named forbidden reconciler flags `--force` and `--reinstall` plus the forbidden
  sister commands `install`, `upgrade`, `repair`, and `force-install` on the chart surface.
- Phase 4 owns Harbor-first lifecycle hardening, the narrowed Harbor-plus-storage-backend
  bootstrap exception, the public AWS-validation Pulumi surface, lifecycle-owned bootstrap DNS
  and ACME projection, Python removal, and the native-host-architecture container-build doctrine.
  The Phase `4` lifecycle now installs MinIO first, bootstraps Harbor's registry bucket plus
  credential secret, reconciles Harbor on S3-backed registry storage, and keeps its later AWS-
  validation and Python-removal surfaces closed on the supported path. Sprint 0.4 extends
  Sprint 4.5 with the same forbidden-flag and sister-command discipline on the lifecycle
  reconciler; the one-cycle `install` alias has been retired, and `install`, `upgrade`,
  `repair`, and `force-install` are rejected at parse time.
- Phase 5 owns public-edge diagnostics and external proof on Route 53, Envoy Gateway, Gateway
  API, certificate readiness, and external browser validation. It includes API, WebSocket,
  Harbor, and MinIO route classification plus named external proofs for those workloads. Sprint
  `5.5` closes this phase's redirect-only port `80` handling and proof while preserving HTTPS as
  the only application-traffic route.
- Phase 6 owns the destructive clean-room rerun and zero-Python repository handoff criteria,
  closed through the aggregate rerun, postflight restore, `config show`, `config validate`,
  `host public-edge`, and supported-path repository review gates for placeholder-domain and Python
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
  paths have landed, while the live whole-system sealed-state proof remains open).
- Direct public-registry pulls are permitted on the supported path only for Harbor and Harbor's
  storage backend during bootstrap.
- Every later Helm deployment must obtain its images through Harbor.
- `prodbox` must idempotently ensure required public images are present in Harbor after Harbor
  bootstrap and before they are referenced by later supported cluster workloads.
- Supported custom-image builds and Harbor publication use only the native architecture of the
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
- The gateway daemon, `prodbox gateway status`, and daemon config parsing must close on the
  implemented bounded HTTP `/v1/state` surface, the Orders-backed interval-validation contract, and the
  current runtime-to-model notes in `documents/engineering/tla_modelling_assumptions.md`.
- The gateway daemon must materialize peer transport from the certificate, key, CA, and socket
  fields already retained in `DaemonConfig` and `Orders`, so `stateLastHeartbeatTimes` is updated
  from inbound peer events rather than from the local heartbeat loop alone, the append-only commit
  log replicates between nodes as the canonical heartbeat-and-event transport, and `/v1/state`
  exposes per-peer transport health.
- The gateway daemon must emit signed `Claim` and `Yield` events on owner transitions and gate
  Route 53 writes on the runtime equivalent of the modelled `CanWriteDns` predicate, so
  `ClaimPrecedesWrite` and `YieldPrecedesReclaim` hold on the runtime event log and a stale owner
  cannot reclaim DNS write authority without first observing its own yield being superseded by a
  fresh claim.
- The supported-host gate must fail fast on unhealthy NTP synchronization, the gateway daemon
  must record the maximum observed inter-node clock skew on `/v1/state` and refuse inbound
  heartbeats whose timestamps exceed the documented bound, and the architecture and TLA+
  correspondence docs must name that bound, the operator response, and how the model's
  bounded-delay assumption maps to a runtime-enforced skew limit.
- Orders documents must carry a monotonic version field, daemons must reject inbound peer events
  from a peer presenting an older Orders version, a new Orders version must propagate through the
  commit-log gossip surface and be adopted by every live daemon before the next election tick,
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
