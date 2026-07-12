# Helm Chart Platform Doctrine

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [../../README.md](../../README.md),
[acme_provider_guide.md](acme_provider_guide.md),
[../../DEVELOPMENT_PLAN/README.md](../../DEVELOPMENT_PLAN/README.md),
[../../DEVELOPMENT_PLAN/system-components.md](../../DEVELOPMENT_PLAN/system-components.md),
[../../DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md](../../DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md),
[../../DEVELOPMENT_PLAN/phase-2-gateway-dns.md](../../DEVELOPMENT_PLAN/phase-2-gateway-dns.md),
[../../DEVELOPMENT_PLAN/phase-3-chart-platform-vscode.md](../../DEVELOPMENT_PLAN/phase-3-chart-platform-vscode.md),
[../../DEVELOPMENT_PLAN/phase-5-canonical-test-suite.md](../../DEVELOPMENT_PLAN/phase-5-canonical-test-suite.md),
[../../DEVELOPMENT_PLAN/phase-8-email-invite-auth.md](../../DEVELOPMENT_PLAN/phase-8-email-invite-auth.md),
[../documentation_standards.md](../documentation_standards.md),
[README.md](./README.md), [cli_command_surface.md](./cli_command_surface.md),
[envoy_gateway_edge_doctrine.md](./envoy_gateway_edge_doctrine.md),
[local_registry_pipeline.md](./local_registry_pipeline.md),
[resource_scaling_doctrine.md](./resource_scaling_doctrine.md),
[secret_derivation_doctrine.md](./secret_derivation_doctrine.md),
[storage_lifecycle_doctrine.md](./storage_lifecycle_doctrine.md),
[unit_testing_policy.md](./unit_testing_policy.md),
[vault_doctrine.md](./vault_doctrine.md),
[bootstrap_readiness_doctrine.md](./bootstrap_readiness_doctrine.md),
[lifecycle_control_plane_architecture.md](./lifecycle_control_plane_architecture.md)
**Generated sections**: none

> **Purpose**: Define the singleton chart identity, shared public-edge attachment model, external Patroni
> PostgreSQL dependency model, storage lifecycle, and delete semantics for `prodbox charts`.

## 1. Canonical Doctrine Statements

The chart platform is owned by the native Haskell runtime in:

- `src/Prodbox/CLI/Charts.hs`
- `src/Prodbox/Lib/ChartPlatform.hs`
- `src/Prodbox/Lib/Storage.hs`
- `src/Prodbox/PostgresPlatform.hs`

The supported chart doctrine is:

1. `prodbox charts` manages the repo-owned root charts `gateway`, `keycloak`, `vscode`, `api`,
   and `websocket`, with internal `keycloak-postgres` and `redis` dependency releases.
   Public `status|reconcile|delete` inputs are restricted to those root chart names; the internal
   dependency releases are runtime-owned and are not supported public CLI targets.
2. No repo-owned chart may render or own an embedded PostgreSQL subchart.
3. Helm-managed application PostgreSQL is namespace-local and Patroni-based: the internal
   `keycloak-postgres` release renders a `pgv2.percona.com/v2` `PerconaPGCluster` resource in the
   root chart namespace, and the cluster-wide Percona operator reconciles it.
4. `keycloak` depends on that namespace-local Patroni cluster.
5. `vscode` depends on `keycloak`, does not talk directly to PostgreSQL, targets an
   Envoy-authenticated public browser path rather than a permanent app-local nginx auth proxy,
   and keeps Envoy's OIDC provider token exchange on the namespace-local `keycloak` Service.
6. `api` runs from the shared `prodbox-runtime` union image (`workload start` via the pod `args:`), keeps its workload resources
   namespace-local in `api`, and targets the shared-host JWT-protected `/api` route by attaching
   to the shared `public-edge` `Gateway` published from the `vscode` namespace. Envoy validates
   JWTs against the public issuer but fetches JWKS through an in-cluster backchannel to
   `keycloak.vscode.svc.cluster.local`.
7. `websocket` runs from the shared `prodbox-runtime` union image (`workload start` via the pod `args:`), keeps its workload and
   `redis` resources namespace-local in `websocket`, owns workload-managed OIDC bootstrap on
   `/ws/oidc`, targets the shared-host JWT-protected `/ws` route by attaching to the shared
   `public-edge` `Gateway` in `vscode`, and currently exchanges tokens through a private in-cluster
   backchannel to `keycloak.vscode.svc.cluster.local`. Envoy's JWT JWKS fetch uses the same
   in-cluster Keycloak service boundary.
8. The current supported shared public edge is anchored in the `vscode` namespace, where the chart
   platform publishes the shared `Gateway`, listener certificate, and `/auth` Keycloak identity
   route consumed by the shipped browser, API, WebSocket, and MinIO surfaces.
9. The shared `Gateway` renders a port `80` HTTP listener only for the redirect-only `HTTPRoute`
   named `public-edge-http-redirect`; all backend routes attach to HTTPS listener sections and the
   chart platform does not render plaintext application forwarding.
10. Chart deploy fails fast until the cluster-wide Patroni platform exists. The actionable recovery
   path is `prodbox cluster reconcile`.
11. Chart templates that consume the canonical public-edge path catalog do so through the
    marker-delimited generated `route-registry` blocks maintained by `prodbox dev docs generate`,
    not through hand-maintained inline route inventories.
12. Chart metadata is doctrine-owned: every chart helper exports
    `app.kubernetes.io/name`, `app.kubernetes.io/managed-by: prodbox`, and
    `prodbox.io/chart-root`, and `prodbox dev lint chart` validates those invariants together with
    `Chart.yaml` metadata.
13. Keycloak's NetworkPolicy keeps explicit egress: PostgreSQL, in-namespace Keycloak service
    traffic, cluster DNS, external HTTPS for issuer/OIDC paths, and the configured SMTP port from
    `.Values.smtp.port` for SES-backed invite email.
14. Every repo-owned chart renders explicit cpu, memory, and ephemeral-storage
    `resources.requests` and `resources.limits` for every container and init container, plus explicit
    PVC capacities for every durable claim. A chart without a resource profile is invalid; the chart
    renderer consumes the validated resource plan from
    [resource_scaling_doctrine.md](./resource_scaling_doctrine.md), never a template-local default.
15. Gateway kubelet liveness uses `/healthz` and readiness uses `/readyz`; `/v1/state` is an
    operator diagnostic and is forbidden as either lifecycle probe. Sprint `3.25` binds the
    existing endpoints through the typed `GatewayProbeSpec` source, generated chart defaults, and
    a negative chart-lint guard.
16. The lifecycle control plane renders Bootstrap Broker, Lifecycle Authority, fenced Provider
    Worker, Authority Backup Adapter, TLS Retention Adapter, Target Secret Agent, and Gateway Runtime
    as separately scheduled steady workloads with distinct Services, ServiceAccounts, policies,
    resource envelopes, bounded queues, and readiness identities. Credential Provisioner and Admin
    Action Runner are disjoint on-demand one-shot Job/ServiceAccount roles. A shared image does not
    collapse these authority or scheduling boundaries. Public root-chart names remain unchanged;
    these platform/control-plane workloads are owned by reconcile, not additional
    operator-selected application chart names.
17. Each Gateway emitter is a stable one-replica StatefulSet identity. EKS journals use static
    retained CSI volumes with `ReadWriteOncePod`; home journals use node-affined local/`hostPath`
    PVs and do not claim CSI enforcement. Both substrates require the OS filesystem lock, durable
    incarnation, Kubernetes Lease, and journal/admission-marker read-back before readiness.

## 1A. Chart Lint and Route Inventory Generation

The supported chart-maintenance surface is split between `prodbox dev lint chart` and
`prodbox dev docs generate`.

- `prodbox dev lint chart` validates every chart under `charts/` for the canonical
  `Chart.yaml` metadata fields (`apiVersion: v2`, `name`, `version`, `appVersion`), the
  required chart-label helper lines, values-backed `resources` stanzas on every template
  `containers:` / `initContainers:` item, root-chart `ResourceQuota`/`LimitRange` manifests, and
  drift on the generated `route-registry` sections.
- `prodbox dev docs generate` refreshes the marker-delimited route inventory consumed by:
  - `charts/keycloak/templates/gateway.yaml`
  - `charts/vscode/templates/http-route.yaml`
  - `charts/api/templates/http-route.yaml`
  - `charts/websocket/templates/http-route.yaml`
- The generated route inventory is derived from `src/Prodbox/PublicEdge.hs`, so the public
  path catalog stays synchronized across docs, chart manifests, and validation surfaces.

## 1B. Resource Requirement Rendering

The chart platform consumes a validated resource plan, not raw settings. `Prodbox.Lib.ChartPlatform`
resolves a `ResourceProfileId` for each root chart, internal dependency release, init container, and
sidecar; the resulting profile renders exactly one Kubernetes `resources` stanza per container. The
profile includes request and limit values for cpu, memory, and ephemeral storage. Persistent volumes
continue to use the retained-storage inventory, but their requested capacity must also be represented
as a durable-storage draw in the capacity plan.

The chart-side illegal states are:

- a workload or init container without a resource profile
- a `resources.requests` field without a matching `resources.limits` field
- a limit lower than its request
- a namespace quota lower than the sum of the profiles rendered into that namespace
- a PVC capacity that is not present in the durable-storage budget

Those states are rejected before Helm is invoked. The structural lint scans chart templates so a
future template edit cannot accidentally omit the values-backed resource stanza; the live
`BestEffort`/QoS proof is owned by the canonical `resource-guardrails` validation. Namespace
`ResourceQuota` and `LimitRange` manifests are rendered from the same profile set, making quota and
container limits agree by construction.

## 1C. Lifecycle Control-Plane Workload Rendering

The target renderer projects the topology from
[Lifecycle Control-Plane Architecture](./lifecycle_control_plane_architecture.md):

| Workload | Sole authority | Required isolation |
|---|---|---|
| Bootstrap Broker | bounded Vault init, unlock, baseline, exact genesis-signing/TLS-envelope/retained-material key trust, seal status, and key rotation before Vault is usable | dedicated secret-free controller Service/SA/bootstrap-store policy plus isolated one-shot init and unseal secret workers for password/recovery-key/share handling, bounded queues/envelopes, and readiness identity |
| Lifecycle Authority | authority epoch/time, durable operation journal, leases/fences, primary Model-B CAS, immutable checkpoint references, provider workflow, TLS/secret outboxes, and signed permit projection | dedicated Service/SA/Vault+primary-MinIO policy, typed Adapter/Worker clients only, recovery-reserved queue, and readiness identity; no AWS secret, prompt, plaintext credential, or S3 client |
| Credential Provisioner | one active indexed `GenesisBackupPermit` / `GenesisCleanupPermit` / `RepairPermit` / schema-indexed `OperatorMaterialPermit` identity/store program and direct linear handoff to the named Agent; the retained first-reconcile session may receipt-order only AWS-admin members of the Genesis-bound exact plan | on-demand one-shot Job, dedicated SA/NetworkPolicy/resource envelope, verified Pod UID/image digest/permit/plan/next-member/prior-receipt/deadline/heartbeat binding, authenticated exec/attach stdin, no steady Service/PVC, and deletion read-back; EAB uses a separate schema-bound Job/frame and later actions use a fresh Job/prompt |
| Admin Action Runner | closed `AdminActionPermit` exact SES+SMTP destroy/migrate/compatibility/quota program with stable read-back | distinct on-demand one-shot Job/SA/NetworkPolicy/resource envelope; `DestroyAwsSes` binds consumer, non-credential SES/S3, SMTP IAM, target-generation, and custody absence stages; no credential-provision, provider, or decommission program |
| Fenced Provider Worker | closed normal provider intents, including non-credential SES/S3, and bounded scratch checkpoint execution/read-back | dedicated Deployment/Service/SA/queue/scratch budget and lifecycle-provider-only Vault role; no SMTP IAM identity/policy/key, prompt, credential permit, backup/TLS, or Authority-state policy |
| Authority Backup Adapter | closed Authority prepare/blob/receipt/restore/GC protocol against the exact long-lived S3 prefix | dedicated Deployment/Service/SA/NetworkPolicy, `secret/aws/authority-backup-store`-only Vault role, managed session, bounded queue/resource envelope, and no provider/target/Gateway API |
| TLS Retention Adapter | ciphertext/wrapped-DEK retain/read-back and restore-byte protocol for exact `public-edge-tls/<substrate>/<fqdn>` versions | dedicated Deployment/Service/SA/NetworkPolicy, `secret/aws/tls-retention-store`-only Vault role, bounded queue/resource envelope, and no plaintext/backup/provider/target policy |
| Target Secret Agent | durable receipt sealing/continuation, allowlisted generation-checked Vault KV, opaque HMAC commitments, dedicated TLS Kubernetes-Secret capabilities, and on home the TLS-envelope plus closed SMTP/EAB custody/rewrap Transit lanes | one controller identity per substrate plus isolated one-shot secret-worker SA/session; exact receipt/target-KV and `prodbox-target-secret-commitment-<substrate>` HMAC-only policy, exact TLS Secret RBAC, and home-only non-exportable TLS/custody Transit policies; separately bounded normal, custody/rewrap, and selected-target materialization queues/envelopes |
| Gateway Runtime | mesh membership, bounded signed state, ownership projection, DNS, and one encrypted identity-bound local emitter journal per node | stable per-emitter StatefulSet, Service/SA, registered journal PVC, OS lock/incarnation/Lease, bounded emitter mailbox and transport queues, gateway-only Vault policy, and readiness identity |

No ServiceAccount may combine these policies. No Service selector may route one capability to a
Pod that owns another. Gateway Runtime receives no generic MinIO, Pulumi, lifecycle, bootstrap, or
target-Vault permission; its retained journal key is acquired through a managed renewable Vault
session and heartbeat writes remain local. Gateway outage, restart, or queue saturation therefore
cannot consume Lifecycle Authority admission capacity or prevent a durable operation from being
observed, resumed, or closed.

Graph reconnaissance resolves each operation/service/scope requirement to one opaque
`CapabilityRef kind`. The chart supplies the service identity and coordinate for that reference;
it does not inject a separate readiness/probe endpoint. Observation, admission, and execution use
the same reference, and Kubernetes `/readyz` is only a cached admission projection for that
workload's documented capability. A reachable Service, ready Pod, or nominal backend label alone
is not capability evidence.

No Job or Agent plaintext is rendered into argv, environment, ConfigMap, Kubernetes Secret,
filesystem, PVC, event, status, or log. Prompt bytes reach a verified Job only through authenticated
`pods/exec` stdin or attach after Pod UID, immutable image digest, ServiceAccount, permit binding,
absolute deadline, and host heartbeat validation. Secret-bearing workers disable swap/core dumps,
use bounded lifetime/memory, revoke sessions, terminate, and are deletion-read-back. They
best-effort zeroize only owned mutable/mlocked buffers; rendering and qualification make no claim
that Haskell immutable values, TLS/SDK libraries, or GC copies were byte-erased.

AWS-admin and external-EAB ingress are different rendered permit schemas and linear frame decoders.
The first-reconcile session can retain only its bounded AWS-admin frame; it cannot accept EAB bytes
or switch schema. Credential Provisioner derives region-bound `SesSmtpSource` before home-custody
handoff, so neither the home Agent nor any ConfigMap/Secret receives raw IAM secret-access-key bytes.

TLS worker RBAC is generated from the exact `(substrate, FQDN, namespace, Secret name)` catalog.
Observe/seal and materialize/read-back are distinct capability kinds and neither admits arbitrary
Secret list/watch. Restore startup is ordered before cert-manager issuance: Authority names the
receipt-committed immutable TLS-retention version, the Adapter returns bounded ciphertext/wrapped-
DEK bytes, retained-home Agent rewraps the DEK to the newly attested selected worker, and that worker
CAS-applies/read-backs the exact Secret. Corrupt, digest-mismatched, unobservable, not-yet-valid, or
Authority-time-uncertain state blocks issuance; only positive absence or expiry proven by the pure
trusted-Authority-time fold may lead to a separately committed issuance plan. AWS qualification
deletes/recreates AWS Vault and EBS and proves this restore path before issuance.

The former same-binary gateway pre-Vault mode, gateway object-store/federation/target-secret routes,
and gateway-held lifecycle permissions are historical implementation surfaces retained only for
the plan-owned epoch cutover. Implementation and deployment-qualification status remain exclusively in
the Development Plan.

## 2. Singleton Chart Identity Rule

One Helm release per chart name exists cluster-wide at any time.

- Before deployment, the Haskell runtime inspects `helm list --all-namespaces`.
- If any release in the plan already exists, `prodbox charts reconcile <chart>` reports the current
  deployment surface as success and performs no Helm or storage mutation.
- Resetting the chart stack still requires an explicit `prodbox charts delete <chart>` first.

## 3. Root-Chart Workload Namespace and Shared Public-Edge Attachment Rule

The root chart name still determines the owning workload namespace for chart-local resources, but
the current supported public edge is shared.

- `prodbox charts reconcile gateway` deploys into the `gateway` namespace.
- `prodbox charts reconcile keycloak` deploys `keycloak-postgres` plus `keycloak` into the
  `keycloak` namespace.
- `prodbox charts reconcile vscode` deploys `keycloak-postgres`, `keycloak`, and `vscode` into the
  `vscode` namespace and publishes the shared `public-edge` `Gateway`, the HTTPS listener
  certificate, the redirect-only HTTP listener and route, and the `/auth` Keycloak route used by
  the supported shared-host edge and the authenticated `prodbox users` invite API.
- `prodbox charts reconcile api` deploys its workload and JWT `SecurityPolicy` into the `api`
  namespace, then attaches its `HTTPRoute` to the shared `public-edge` `Gateway` in `vscode`
  through a cross-namespace `parentRef`.
- `prodbox charts reconcile websocket` deploys `redis`, its workload, and JWT `SecurityPolicy` into
  the `websocket` namespace, then attaches its `/ws` and `/ws/oidc` `HTTPRoute` resources to the
  shared `public-edge` `Gateway` in `vscode` through cross-namespace `parentRefs`.

Repo-owned charts keep workload resources in their owning namespaces, but the current shared-host
doctrine explicitly allows cross-namespace `HTTPRoute` attachment to the shared `public-edge`
`Gateway` in `vscode`. The WebSocket workload also carries one current private cross-namespace
runtime contract to `keycloak.vscode.svc.cluster.local` for token exchange. The only cluster-wide
dependency beyond that shared-edge model is the lifecycle-owned Percona PostgreSQL operator in the
`postgres-operator` namespace.

## 3A. Substrate-Equivalence Mechanism

The home local substrate and the AWS substrate stand up the same platform components; the only
deliberate differences are the lower-layer load balancer (MetalLB on home, AWS Load Balancer
Controller on EKS), Route 53 hosting, and the block-storage volume source (a `hostPath` under
`.data/` on home, a pre-created EBS volume on EKS). The storage *discipline* is identical on
both substrates — the static `manual` no-provisioner `Retain` PV model with deterministic
rebinding, no dynamic provisioning (Sprint `7.28`;
[storage_lifecycle_doctrine.md § 1](./storage_lifecycle_doctrine.md)). Substrate equivalence is
enforced as a structural invariant, not maintained by parallel hand-edited installers
(Sprint 7.12):

1. **One release value per platform component image.** The Envoy Gateway control-plane image, the
   Envoy data-plane image, and the cert-manager image set are each pinned to exactly one
   `Prodbox.ContainerImage` release value, shared by the chart, the control plane, and the data
   plane. There is no separate per-substrate Envoy or cert-manager version. This kills version
   skew of the EG-control-plane-vs-Envoy-data-plane kind (the EG-1.4.4 / Envoy-1.37 skew class):
   a single release value pins the chart, control plane, and data plane together.
2. **A lint forbids per-substrate chart-version or image re-pinning.** No `prodbox` code path may
   re-pin a chart version or image ref conditionally on the active substrate
   (`Prodbox.Lib.AwsSubstratePlatform` may not override the shared `Prodbox.ContainerImage`
   values that `Prodbox.Lib.ChartPlatform` uses). The lint fails closed on any substrate-keyed
   re-pin, so "AWS needs a different Envoy version" is a build-time error, never a silent
   divergence.
3. **A shared `[PlatformComponent]` inventory drives both installers.** Both the home-substrate
   reconcile and the AWS substrate-platform install draw from one `[PlatformComponent]` list
   (the in-cluster registry (registry:2), MinIO, the Percona PostgreSQL operator, MetalLB-or-ALB-controller, Envoy Gateway,
   cert-manager). A coverage test asserts both installers cover every entry — it is **not** a
   unified step DAG; each substrate keeps its own ordering, but neither may silently drop a
   component the other installs. The AWS substrate is **not** a "no-registry" cluster.

This is the chart-platform-side statement of the substrate-equivalence doctrine in
[../../CLAUDE.md](../../CLAUDE.md) "Substrate Equivalence" and
[../../DEVELOPMENT_PLAN/substrates.md](../../DEVELOPMENT_PLAN/substrates.md). When AWS appears to
be "missing" a platform piece the home cluster has, the fix is to extend the shared inventory and
the AWS installer, never to render different image refs or re-pin versions per substrate.

## 4. Patroni PostgreSQL Dependency Contract

The application database is not an embedded subchart. It is a separate Helm-managed release in the
same namespace as the consuming chart stack.

The supported contract is:

- `prodbox cluster reconcile` installs the cluster-wide `percona/pg-operator` Helm release into the
  `postgres-operator` namespace. The chart → operator readiness gate proves the operator Deployment
  is **`Available`** (reconciling), not merely that it exists (Sprint `3.23`); and the chart dependency
  edges below are sourced from the typed component graph, not hardcoded, per
  [bootstrap_readiness_doctrine.md](./bootstrap_readiness_doctrine.md). Sprint `3.24` installs the
  ChartPlatform production binding to Sprint `1.59`'s typed seam. The graph-projected gate resolves
  through the exhaustive `operatorAvailableTarget` registry, an `OperatorAvailableTarget`, and
  `observeComponentReadiness`; both pending and unreachable observations close chart mutation. The
  Percona one-shot adapter first queries the CRD and then the operator Deployment, using
  `--ignore-not-found` for both, and opens only for `Available=True`. Every current unsupported
  `ComponentId` has an explicit fail-closed registry arm. A newly added constructor therefore
  requires a warning-clean source match, while configuration that selects an existing unsupported
  ID is refused at runtime rather than misdescribed as universally compile-time impossible.
- `prodbox charts reconcile keycloak` and `prodbox charts reconcile vscode` include the internal
  `keycloak-postgres` release before `keycloak`.
- Each Patroni cluster runs exactly three PostgreSQL replicas.
- Patroni synchronous replication is enabled across the supported three-replica steady state.
- The PostgreSQL workload images are registry-backed:
  `percona-distribution-postgresql-mirror:17.9-1`,
  `percona-pgbouncer-mirror:1.25.1-1`, and `percona-pgbackrest-mirror:2.58.0-1`.
- Keycloak consumes the namespace-local retained credentials secret
  `prodbox-<root-chart>-pg-pguser-keycloak`.
- The primary service endpoint is `prodbox-<root-chart>-pg-ha.<namespace>.svc.cluster.local`.
- The replica-read service endpoint is
  `prodbox-<root-chart>-pg-replicas.<namespace>.svc.cluster.local`.
- The canonical Percona operator namespace, release, CRD, service, and secret naming contract
  lives in `src/Prodbox/PostgresPlatform.hs`.

The chart runtime validates the platform prerequisite by requiring both:

- CRD `perconapgclusters.pgv2.percona.com`
- deployment `postgres-operator` in namespace `postgres-operator`

before any chart that depends on PostgreSQL is deployed.

After the internal `keycloak-postgres` release installs, the chart runtime waits for the Percona
cluster to report `.status.state=ready` and `.status.postgres.ready=3` before it deploys
`keycloak` or later dependent charts. Before the retained Patroni cluster is recreated, the chart
runtime reinitializes retained follower roots for ordinals `1` and `2` so those replicas rejoin
from the preserved cluster anchor instead of trying to continue from stale follower-local WAL
state.

Patroni retained-claim discovery and cluster-readiness waits classify transient PostgreSQL
convergence failures as `PgError` and run through `retryServiceAction`. Chart-platform
PostgreSQL discovery, readiness, restore, retained-claim, and cleanup paths now use the
`HasPg` capability boundary, and there is no direct chart-platform `redis-cli` call site.
New chart-platform service interactions should use the capability boundary rather than adding
direct subprocess call sites.

When retained Patroni state already exists, the chart runtime stages restore deliberately:

- preserve the retained ordinal `0` anchor PV and secret state
- reconcile `keycloak-postgres` first at one PostgreSQL replica against that preserved anchor
- wait for the single-node cluster to report ready
- scale the Percona cluster back to the supported three-replica synchronous steady state before
  dependent charts continue

## 5. CLI-Owned PV/PVC Lifecycle

Repo-owned charts never create `PersistentVolume` objects directly.

- The Haskell CLI creates deterministic PV objects for retained workloads.
- Direct retained workloads such as `vscode` still use CLI-created PVC objects before Helm runs.
- Percona-managed PostgreSQL clusters create their own PVC objects through the operator.
- After the Percona cluster creates those PVCs, the Haskell runtime discovers the actual claim
  names and binds the deterministic retained PVs to those claims.
- Deterministic PV names and Patroni cluster or secret names flow through
  `src/Prodbox/Naming.hs` rather than through open-coded string concatenation.
- Patroni service names, PVC names, and the three-replica storage-spec inventory flow through
  `src/Prodbox/PostgresPlatform.hs`, and chart-platform storage pairing flows through
  `storageBinding` in `src/Prodbox/Lib/Storage.hs`.

There is no Pulumi-owned PostgreSQL exception on the supported path.

## 6. `.data/<namespace>/<StatefulSet>/<ordinal>` Host-Path Contract

Chart-owned retained host storage lives at:

```text
<repo-root>/.data/<namespace>/<StatefulSet>/<ordinal>
```

There is no per-host machine-id prefix and no `<release>` or `<claim>` path segment; the
PVC↔PV identity is carried by `claimRef`, not by the directory layout. Examples:

- `keycloak-postgres` Patroni cluster for the `keycloak` root chart:
  `.data/keycloak/prodbox-keycloak-pg/0`
- the same Patroni dependency deployed under the `vscode` root chart:
  `.data/vscode/prodbox-vscode-pg/0`
- `vscode` StatefulSet:
  `.data/vscode/vscode/0`
- `minio` StatefulSet (in the shared `prodbox` namespace):
  `.data/prodbox/minio/0`
- `vault` StatefulSet:
  `.data/vault/vault/0`

Rules:

1. The CLI creates host directories before storage manifests are applied.
2. `.data/` is reserved for PV contents only.
3. PV names are deterministic and flow through `src/Prodbox/Naming.hs`.
4. `manual` is the only supported `StorageClass` on both substrates. On home its PVs use a
   `hostPath` volume source; on EKS the same `manual` class binds pre-created EBS volumes
   lifted in as static `Retain` PVs (CSI `volumeHandle`, AZ affinity) — no dynamic
   provisioning. See [storage_lifecycle_doctrine.md § 1](./storage_lifecycle_doctrine.md)
   (Sprint `7.28`).
5. Retained application/platform data workloads — `minio`, the Patroni PostgreSQL cluster,
   `vscode`, and `vault` — are StatefulSets; `minio`, `vscode`, and `vault` are single-replica and
   the Patroni cluster is three-replica, so each contributes one PV per ordinal. Each Gateway
   emitter is also a stable one-replica StatefulSet identity and binds one separately registered
   identity-bound emitter-journal PVC. On EKS that static EBS CSI claim is
   `ReadWriteOncePod`; on home the local/`hostPath` PV is node-affined and exclusion instead composes
   node pinning, the OS lock, durable incarnation, and Kubernetes Lease.
6. The MinIO PV at `.data/prodbox/minio/0` holds the generic `prodbox-state` bucket. Sprint `4.30`
   routes Model-B logical objects, including the production in-force config read, through
   `prodbox-envelope-v2` Vault-Transit envelopes stored under Vault-keyed-HMAC opaque IDs
   (`objects/<opaque-id>.enc`). Sprint `7.14` routes main Pulumi checkpoints through the same
   encrypted object-store wrapper and imports legacy raw checkpoints on first touch. Sprint `4.33`
   gates the Haskell-side residue/oracle/log surfaces behind Vault readiness, and Sprint `5.8` owns
   the deployed host-disk/Kubernetes/log red-team proof. The Model B object-store
   contract is owned by [vault_doctrine.md §9](./vault_doctrine.md#9-minio-as-a-ciphertext-store)
   and the on-disk persistence statement by
   [storage_lifecycle_doctrine.md](./storage_lifecycle_doctrine.md).

All non-PV chart state lives inside the cluster as native k8s Secrets and ConfigMaps. Gateway
emitter continuity is PV state by design: each admitted node has one encrypted identity-bound
retained journal volume registered in the lifecycle inventory; it is never reconstructed from peer
state or stored in a generic gateway Model-B object.
No `prodbox` command writes to `.prodbox-state/`; the directory is removed from the
supported architecture and the `forbidDotProdboxState` lint in `prodbox dev check`
enforces this. Every chart secret — Patroni roles, Keycloak admin, OIDC client
secrets, gateway peer-event keys, demo-user passwords — is a Vault KV object fetched
in-cluster via Vault Kubernetes auth per
[Secret Derivation Doctrine](./secret_derivation_doctrine.md) and
[vault_doctrine.md](./vault_doctrine.md). The master-seed HMAC-derivation model and the
Helm `lookup`-guarded `randAlphaNum` chart-generated secret idiom are both retired:
secrets are generated once and persisted on Vault's durable storage, not reconstructed
from a seed or regenerated by chart templates. When Vault is sealed, no chart secret
resolves and secret-dependent Pod startup fails closed; new Pods never reconstruct
secret material from any non-Vault source. (Vault-only chart-secret consumption is
active under Sprint 3.18 for the policy/role/service-account, Kubernetes-auth config, and
seed-bootstrap foundation. The websocket OIDC client-secret resolves directly via app-side
`SecretRef.Vault`, the Keycloak and MinIO charts materialize their covered runtime secrets through
Vault-login init containers, and MinIO admin bootstrap Jobs read root credentials through the same
Vault-auth pattern. The VS Code Envoy `SecurityPolicy` client Secret is materialized from Vault by
a chart Job, Gateway event and dedicated Gateway-DNS credentials resolve through the Gateway role
(never the Lifecycle-provider or cert-manager paths), and the current
gateway MinIO credential is historical cutover residue, while Patroni
  role Secrets are materialized from Vault by the `keycloak-postgres` pre-install hook. Setup/admin
  helper reads, the sealed-startup structural proof, and the Sprint 3.19 legacy derivation/RPC
  removal have landed.)

### Daemon and workload config mount contract

Every `prodbox`-launched in-cluster process (Bootstrap Broker controller/worker, Lifecycle Authority, Provider Worker,
Authority Backup Adapter, TLS Retention Adapter, Target Secret Agent controller/worker, Credential
Provisioner Job, Admin Action Runner Job, Gateway Runtime, and workload Pods) takes its
runtime configuration from exactly one Dhall file at `--config`, per
[config_doctrine.md](./config_doctrine.md). The chart-side rendering of that surface
follows a uniform mount layout:

| Mount source | Mount path | Content |
|---|---|---|
| `<release>-config-<podId>` ConfigMap | `/etc/<release>/config.dhall` (gateway exception below) | per-Pod Dhall expression; sensitive fields are `SecretRef.Vault` references, not inline credential imports |
| `<release>-orders` ConfigMap (gateway only) | `/etc/gateway/orders.dhall` | cluster-wide ranked-node + timing Dhall expression |
| Cert-manager-issued per-Pod TLS Secret | `/tls/` | TLS keypair referenced by file path from the Dhall config |
| Cert-manager CA Secret | `/ca/` | trust anchor referenced by file path from the Dhall config |

The gateway daemon is the mount-shape exception to the uniform row above: its ConfigMap is a
**directory** mount at `/etc/gateway/config` (no `subPath`, so the kubelet's atomic `..data`
swap fires the fsnotify reload), and the daemon reads `--config /etc/gateway/config/config.dhall`
— the `config.dhall` file inside that directory. The same ConfigMap carries a sibling
`prodbox.dhall`: the supported planner renders a daemon-frame Tier-0 document with the selected
substrate's explicit cluster identity (established home Tier-0 identity or canonical EKS cluster
name). The empty default values omit that sibling for generic chart linting; production generated
values always supply it. See
[config_doctrine.md §6-§7](./config_doctrine.md#6-cluster-mount-contract).

Bootstrap Broker, Lifecycle Authority, Provider Worker, Authority Backup Adapter, TLS Retention
Adapter, and Target Secret Agent use separate directory-mounted ConfigMaps under
`/etc/<component>/config`, with distinct ServiceAccounts and policies matching §1C. Substrate
identity and target KV allowlist live only in the Target Secret Agent document; that document also
fixes the exact seal-receipt KV prefix, bounded secret-worker limits, receipt-retention/GC window,
enumerated TLS Kubernetes Secret identities, and (home only) the `prodbox-tls-envelope` Transit
lane plus the closed SMTP/EAB retained-material custody/rewrap lane and exact receipt catalog. Each
substrate role also gets HMAC-only access to its exact
`prodbox-target-secret-commitment-<substrate>` key, with no key export/list. Vault-KV, commitment
HMAC, TLS-Secret RBAC, TLS-envelope, retained-material custody, and selected-target materialization
capabilities have distinct references and policy documents. Custody/rewrap and target
materialization have separate bounded worker counts, envelope-size limits, Transit/Vault latency
budgets, attestation bounds, deadlines, and retry-after policies, so neither can starve ordinary
Target-Agent or Authority work.

Primary Model-B/provider/outbox coordinates and typed Worker/Adapter references live only in
Lifecycle Authority. `secret/aws/lifecycle-provider` lives only in Provider Worker config/policy;
the exact Authority-backup prefix and `secret/aws/authority-backup-store` live only in Authority
Backup Adapter; exact `public-edge-tls/<substrate>/<fqdn>` prefixes and
`secret/aws/tls-retention-store` live only in TLS Retention Adapter; pre-Vault and exact
genesis-signing/TLS-envelope-key specifications live only in Bootstrap Broker. Gateway config
carries none of those coordinates.

Credential Provisioner and Admin Action Runner Jobs receive role/bounds/trust-only Dhall configs;
they fetch the already committed signed permit through their authenticated Authority channel after
attestation. The Credential Job additionally fixes exactly one ingress schema; it cannot decode an
AWS-admin frame as EAB or vice versa. No prompt or created credential is a config value. The two Jobs use different
ServiceAccounts, NetworkPolicies, program-tag allowlists, and permit decoders; Provider Worker and
Decommission Runner use neither.

The operator-facing ConfigMap holds no secret material — sensitive fields are typed
`SecretRef.Vault` references that each consumer resolves against Vault at runtime.
There is no Secret-mounted plaintext Dhall fragment and no `as Text` credential
import: in-cluster consumers authenticate to Vault directly via Vault Kubernetes auth
(a workload service account, a namespace + SA-bound Vault role, and a least-privilege
policy), per [vault_doctrine.md §12](./vault_doctrine.md#12-in-cluster-service-auth). The target
Gateway Runtime policy is limited to peer/DNS material and renewable local-journal key access; it
cannot read bootstrap, Model-B, Pulumi, lifecycle, or target-secret data.

**Historical implementation record (legacy cutover surface):** Sprint `2.30`
single-sources the gateway-daemon role on the supported generated-render path:
`Prodbox.Vault.RoleId` defines `VaultRoleGatewayDaemon :: VaultRoleId`, and `vaultRoleIdText`
projects it to `prodbox-gateway-daemon`. Both the generated gateway release values in
`Prodbox.Lib.ChartPlatform` and `defaultVaultReconcilePlan`'s `VaultKubernetesRoleSpec` consume that
projection. The role spec binds exactly `["prodbox-gateway", "gateway-gateway"]`. Unit tests pin
those two policies, build and decode the actual generated AWS gateway release values to prove
`vault.role` is the typed projection, and scan `ChartPlatform.hs` to forbid a duplicated
`"prodbox-gateway-daemon"` literal.

The static `charts/gateway/values.yaml` file retains the same role name as the documented chart
default. It is not the typed consumer proved by Sprint `2.30`: the supported `prodbox charts
reconcile gateway` generated values override this field from `VaultRoleId`. This is a precise
gateway-daemon role-identity guarantee, not a claim that every gateway configuration value is
single-sourced.
ConfigMap volume updates land in the Pod via the kubelet's atomic `..data` symlink
swap; the daemon's file-watch reload trigger follows that swap rather than the
leaf-file `mtime`. The chart never injects daemon configuration as environment
variables; the only env vars on supported daemon Pods carry k8s runtime metadata the
binary does not read for config. (Vault Kubernetes auth delivery of credential material
has an active Sprint 3.18 policy/role/service-account, auth-config, and seed-bootstrap foundation;
the websocket OIDC SecretRef consumer, Keycloak / MinIO Vault-login init consumers, and MinIO admin
bootstrap Job Vault-init consumers have landed; the VS Code Envoy `SecurityPolicy` client Secret is
Vault-materialized by a chart Job; gateway event/AWS/MinIO Vault consumption has landed in the
historical combined gateway role, whose MinIO authority is a legacy cutover surface; Patroni
role Secret materialization has landed; host/admin helper reads and AWS SES SMTP Vault writes have
landed; sealed-startup structural proof landed.)

### Gateway lifecycle probe contract

The gateway chart renders liveness and readiness from one typed/defaulted probe configuration in
`Prodbox.Gateway.Probe`: liveness targets the daemon's constant-time `/healthz` projection and
readiness targets its constant-time `/readyz` lifecycle projection. `ChartPlatform` emits the same
typed value used to generate the `gateway-probes.values` defaults, and the StatefulSet renders the
path, initial delay, period, timeout, failure threshold, and success threshold from those values.
Neither probe may call `/v1/state`, sort or encode gateway semantic state, or perform a
backend/AWS/Vault check. `/readyz` is a cached projection of managed gateway sessions, emitter
actor state, and queue admission; it does not make a nominal backend claim. Deep capability
observation uses the same operation-indexed `CapabilityRef` later used for admission and execution,
never a separately injected probe endpoint. Run-wide runtime stability remains a separate
time-windowed observer.

Sprint `3.25` landed this chart binding over the constant-time endpoints from Sprint `2.10`.
`prodbox dev lint chart` rejects `/v1/state` in either probe, independent liveness/readiness
negative fixtures pin that refusal, and a golden pins the typed generated defaults. See
[Bootstrap Readiness Doctrine §2.4](./bootstrap_readiness_doctrine.md#24-dependency-readiness-vs-runtime-stability)
and [Distributed Gateway Architecture §11](./distributed_gateway_architecture.md#11-rest-api).

### Probe and route single-source rule

Chart-rendered probe paths, service ports, and identity values are projections of compiled
values, never independently authored strings. Every daemon route path exists once, in the
compiled closed route registry (`GatewayRoute`), and every gateway port, NodePort,
ServiceAccount, and Vault-role value exists once, in the compiled chart statics
(`GatewayChartStatics`); the server dispatcher, client URL construction, and chart
probe/statics rendering all project those same values. A hand-authored probe path string in a
chart template or values file is a defect, as is a hand-mirrored port or identity literal. The
forbidden-literal chart lint enforces the template side: `prodbox dev lint chart` fails closed
on the raw literals in hand-written templates. The in-code generated-section registry remains
the single source of truth for generated-section keys; this document does not enumerate them.
This rule supersedes substring-lint coupling between the daemon route table and chart probe
paths — the registry, not a string scan, makes the rendered probe path and the served route the
same compiled value, and a kubelet probe bound to a non-probe route is unbuildable by smart
constructor. The typed probe configuration in the
[gateway lifecycle probe contract](#gateway-lifecycle-probe-contract) above becomes a
projection of the same registry. Implementation is owned by Sprint `2.34`; see the
[Development Plan](../../DEVELOPMENT_PLAN/README.md) and
[Lifecycle Control-Plane Architecture §10.2](./lifecycle_control_plane_architecture.md).

## 7. Delete Semantics

`prodbox charts delete <chart>`:

1. calls `helm uninstall` for each release in reverse dependency order
2. deletes Percona PostgreSQL pods and PVCs by selector in the root-chart namespace
3. deletes deterministic retained PVs
4. deletes the root-chart namespace
5. preserves `.data/` on disk (the sole retained operator-host root; no other
   per-cluster state is preserved across delete/reinstall, per
   [Retained Storage Lifecycle Doctrine](./storage_lifecycle_doctrine.md))

This means a later deploy can rebind to the same retained host state.

## 8. Supported Charts

The chart registry is defined in `src/Prodbox/Lib/ChartPlatform.hs`.

Internal entries appear in the registry for runtime dependency planning
only. The public `prodbox charts ...` surface is restricted to root
chart names.

| Chart | Kind | Dependencies | External Requirements | Storage | Public Host Required |
|-------|------|--------------|-----------------------|---------|----------------------|
| `keycloak-postgres` | internal | none | Patroni platform | 3 x 20Gi | no |
| `redis` | internal | none | none | none | no |
| `keycloak` | root | `keycloak-postgres` | none beyond dependency | none | yes |
| `vscode` | root | `keycloak` | none beyond dependency chain | 50Gi | yes |
| `api` | root | none | shared `vscode`-anchored public edge plus shared Keycloak contract | none | yes |
| `websocket` | root | `redis` | shared `vscode`-anchored public edge plus shared Keycloak contract | none | yes |
| `gateway` | root | none | none | one retained encrypted emitter-journal PVC per admitted node | yes |

Root charts:

- `gateway` deploys the in-cluster distributed gateway stack into the `gateway` namespace.
- `keycloak` deploys `keycloak-postgres` plus `keycloak` into the `keycloak` namespace.
- `vscode` deploys `keycloak-postgres`, `keycloak`, and `vscode` into the `vscode` namespace and
  anchors the shared public-edge `Gateway`, HTTPS certificate, redirect-only HTTP route, and
  `/auth` route there.
- `api` deploys the JWT-protected public API workload into the `api` namespace and attaches its
  `HTTPRoute` to the shared `public-edge` `Gateway` in `vscode`; its `SecurityPolicy` keeps the
  public issuer while fetching JWKS from the in-cluster Keycloak service through
  `remoteJWKS.backendRefs` and a `ReferenceGrant` in `vscode`.
- `websocket` deploys the Redis-backed public WebSocket workload into the `websocket` namespace,
  attaches its `HTTPRoute` resources to the shared `public-edge` `Gateway` in `vscode`, and uses a
  private token-endpoint and JWT JWKS backchannel to `keycloak.vscode.svc.cluster.local`.

## 9. Supported Public Auth Model

The supported `vscode` public path is:

1. Envoy Gateway owns TLS termination, Gateway API routing, and browser-facing edge auth
   enforcement.
2. Keycloak remains the OIDC identity provider.
3. `code-server` is reachable only through the Envoy-authenticated public route.
4. Keycloak stores its data in the namespace-local Patroni cluster for the root chart.
5. Supported image refs are registry-only for `keycloak`, `code-server`, the Envoy Gateway public
   edge image set, the Percona operator, and the Percona PostgreSQL workload after the registry
   bootstrap.

The current implementation boundary is:

- `vscode` uses Envoy-managed browser OIDC enforcement through `SecurityPolicy`; browser
  authorization redirects stay on the public issuer, while Envoy's provider backchannel uses the
  namespace-local `keycloak` Service on port 8080.
- `api` uses Envoy-local JWT validation plus route-claim authorization through `SecurityPolicy`,
  with its `HTTPRoute` attached from namespace `api` to the shared `public-edge` `Gateway` in
  `vscode`; the issuer stays public, while `remoteJWKS` fetches signing keys from the in-cluster
  Keycloak service through a cross-namespace backend reference granted by `ReferenceGrant`.
- `websocket` uses workload-managed OIDC bootstrap and cookie-backed session ownership on
  `/ws/oidc`, Envoy-local JWT validation plus route-claim authorization on `/ws`, Redis-backed
  reconnect-safe workload state, readiness-based drain for live upgraded connections, and a private
  token-endpoint and JWT JWKS backchannel to `keycloak.vscode.svc.cluster.local`.
- `keycloak` stays on the shared public hostname under `/auth` and publicly exposes only the
  identity-route surfaces the shipped browser and workload-managed OIDC flows require plus
  `/auth/admin` for the authenticated operator invite API; on the current supported public-edge
  path, the shared `Gateway`, listener certificate, and identity route are anchored in the
  `vscode` namespace.
- Chart reset must not treat production ACME issuance as disposable chart state. The public-edge
  **production** TLS certificate is reclassified from disposable PerRun chart state to a
  rate-limit-safe `LongLived` resource (Sprints 4.24/7.11/8.7). Its material is retained in the
  long-lived `pulumi_state_backend` S3 bucket by the separately credentialed TLS Retention Adapter
  under the substrate-scoped key `public-edge-tls/<substrate>/<fqdn>`. The Adapter receives only
  ciphertext, retained-home-Transit-wrapped DEK bytes, public certificate metadata, and digests;
  it has no Authority-backup/provider credential or plaintext path. The per-substrate/FQDN
  Authority fold serializes immutable versions and promotes only a source-Secret-reobserved,
  Adapter-read-back current ref. Restore always names that committed ref, never S3 latest. Material
  is restored before every issuance on **all** rebuild
  paths — including a fresh cluster after `prodbox cluster delete`, not only the
  chart-delete→redeploy path that the superseded `vscode/public-edge-tls` →
  `prodbox/public-edge-tls-retained` in-cluster Secret copy covered. The
  `preservePublicEdgeTlsSecretBeforeDelete` silent-success gap is closed: the preserve path emits
  typed/logged outcomes and never reports silent success when the owned certificate is absent (the
  soundness rule restored in [lifecycle_reconciliation_doctrine.md §3.1](./lifecycle_reconciliation_doctrine.md#31-the-managed-resource-registry-the-reconciler-substrate)).
  The high-churn canonical validation loop does not re-order the certificate against a separate test
  issuer; the single `zerossl-dns01` `ClusterIssuer` issues the production certificate once and the
  S3 retain-and-restore path restores it on every rebuild. See
  [acme_provider_guide.md](./acme_provider_guide.md#2-zerossl) for the ZeroSSL ACME provider and the
  single-issuer rebuild-safe certificate retention model, and
  [../../DEVELOPMENT_PLAN/substrates.md → Resource Lifecycle Classes](../../DEVELOPMENT_PLAN/substrates.md#resource-lifecycle-classes)
  for the lifecycle-class registration; retained material is removed only by explicit public-edge
  consumer decommission or `prodbox nuke`. Because TLS and Authority backup share the bucket, TLS
  decommission deletes exact prefix versions and its identity but never the bucket; the final
  Authority-backup nuke node proves every prefix absent before bucket deletion.
- Public API and WebSocket workloads still follow the same public-edge doctrine and do not add
  chart-local auth proxies, extra public `Gateway` resources, or a parallel ingress model.

The canonical public-edge doctrine and Redis, JWT, or WebSocket guidance live in
[Envoy Gateway Edge Doctrine](./envoy_gateway_edge_doctrine.md).

## 10. Required Settings and Auto-Generated Secrets

The following repository configuration values are required for the supported public workload
catalog:

| Setting | Purpose |
|---------|---------|
| `domain.demo_fqdn` | Canonical shared public hostname for `/auth`, `/vscode`, `/api`, `/ws`, and `/minio` |

Namespace-local chart secrets are Vault KV objects, fetched in-cluster via Vault
Kubernetes auth and materialized only at the consuming workload boundary per
[Secret Derivation Doctrine](./secret_derivation_doctrine.md) §6:

| Secret (logical key) | Runtime materialization | Source |
|---|---|---|
| `keycloak_admin_password` | Keycloak Vault-init env file | Vault KV, fetched via Vault k8s auth |
| `patroni_app_password` | `prodbox-<root-chart>-pg-pguser-keycloak` | Vault KV, fetched by the `prodbox-<namespace>-pg` materializer hook |
| `patroni_superuser_password` | `prodbox-<root-chart>-pg-pguser-postgres` | Vault KV, fetched by the `prodbox-<namespace>-pg` materializer hook |
| `patroni_standby_password` | `prodbox-<root-chart>-pg-primaryuser` | Vault KV, fetched by the `prodbox-<namespace>-pg` materializer hook |
| `keycloak_vscode_client_secret` | Keycloak Vault-init env file; `vscode` Envoy consumer still being migrated | Vault KV, fetched via Vault k8s auth |
| `keycloak_api_client_secret` | Keycloak Vault-init env file | Vault KV, fetched via Vault k8s auth |
| `keycloak_websocket_client_secret` | Keycloak Vault-init env file; websocket `SecretRef.Vault` for its app-side consumer | Vault KV, fetched via Vault k8s auth |
| `keycloak_demo_user_password` | Keycloak Vault-init env file | Vault KV, fetched via Vault k8s auth |
| `minio_root_credentials` | MinIO Vault-init credential files | Vault KV, fetched via Vault k8s auth |

Every row is a Vault KV object: each secret is generated once and persisted on Vault's
durable storage, so credentials survive underneath preserved PostgreSQL data exactly as
the Vault PV (`.data/vault/vault/0`) survives cluster wipes. There is no master seed and
no HMAC re-derivation; there is no chart-template `lookup` + `randAlphaNum` generation.
On each `prodbox charts reconcile <chart>` the in-cluster consumer authenticates to
Vault via Vault Kubernetes auth (a workload service account, a namespace + SA-bound
Vault role, and a least-privilege policy) and reads its secrets from Vault KV. When
Vault is sealed, none of these secrets resolve and secret-dependent startup fails closed.
(Vault-KV chart-secret consumption is active under Sprint 3.18 for the typed policy/role
inventory and chart ServiceAccounts; the websocket root chart now reads its OIDC client secret
through direct app-side SecretRef resolution, while Keycloak and MinIO materialize their covered
runtime fields through Vault-login init containers, and the VS Code Envoy `SecurityPolicy` client
Secret is materialized from Vault by a chart Job. Gateway event and dedicated Gateway-DNS
credentials resolve from the Gateway role; provider and cert-manager credentials do not;
the current gateway MinIO credential is historical cutover residue. Patroni role Secrets are
materialized from Vault by the `keycloak-postgres` hook;
host/admin helper reads, AWS SES SMTP Vault writes, sealed-startup structural proof, and Sprint
3.19 legacy derivation/RPC removal have landed.)

When `api` or `websocket` deploy as separate root charts, the same Vault-k8s-auth
retrieval path runs for their namespaces and they read the shared `keycloak_*` client
values from Vault KV as already generated. The `vscode` SecurityPolicy, API/WebSocket JWT `remoteJWKS` policies, and WebSocket
workload all keep provider/token/JWKS backchannels in-cluster (`keycloak` Service for
namespace-local VS Code; the shared `keycloak.vscode.svc.cluster.local:8080` endpoint for
separately deployed API/WebSocket) rather than depending on a second public identity surface or
public-load-balancer hairpin behavior. The host-side MinIO console admin route uses the same
public-edge rule: substrate-aware public issuer and redirect URLs, plus the shared internal
Keycloak token endpoint for Envoy's provider exchange. The AWS substrate platform installs those
admin routes after the platform MinIO bootstrap.

The gateway chart emits Namespace resources for cross-namespace RBAC targets such as `keycloak`
and `vscode`. SMTP sync no longer pre-creates namespace-local SMTP Secrets. In the target flow,
Credential Provisioner derives region-bound `SesSmtpSource` from the one-time IAM response and the
retained-home Agent Transit-seals/reads back its closed custody receipt. Lifecycle Authority durably
commits that current receipt, credential generation, and per-target outbox intent. A selected
substrate worker contributes an attested ephemeral public key; a home custody worker decrypts only
the exact current receipt and re-encrypts it to that worker. The selected Agent then starts its
isolated one-shot materializer, decrypts only into bounded memory, performs the
allowlisted generation-checked `secret/keycloak/smtp` Vault KV CAS and mandatory version/opaque-
commitment read-back, best-effort zeroizes owned mutable buffers, revokes the session, exits, and is
deletion-read-back. ACME EAB uses the same closed custody/rewrap shape for `secret/acme/eab` but a
separate external-EAB ingress Job/frame; it never reuses AWS-admin bytes. Its non-secret key ID is
rendered to issuer reconcile only from a typed generation-bound Agent/`ConfigObserve` projection,
while the HMAC is materialized in-cluster; no host Vault client exists. No unkeyed secret hash or
raw IAM secret is persisted or exposed. A source receipt is retained through every target delivery,
rebuild, and supersession/idempotency window and garbage-collected only from a committed intent with
absence read-back. Gateway Runtime is not involved.
Existing Keycloak realms are still patched by
`prodbox users invite` before invite sends because realm import is first-create only, but the helper
now reads the SMTP map from the same Vault KV object the Keycloak chart materializes through its
Vault-login init container.

## Vault as a platform component and chart secret consumption

Vault is the sole, fail-closed secrets root beneath the chart-platform secret model described
above — not a layer added under an older mechanism. Every chart and Keycloak secret is a Vault
KV object; the master-seed HMAC-derivation model and the `lookup`-guarded chart-generated secret
idiom are retired, not retained. `vault_doctrine.md` is the single source of truth for the Vault
model; the statements below are the chart-platform-side summary.

- **Vault is a singleton platform component.** Vault stands up on the same footing as
  MinIO, the in-cluster registry (registry:2), the Percona PostgreSQL operator, Envoy Gateway, and cert-manager, drawn from the
  same shared `[PlatformComponent]` inventory (§3A) so it installs identically on both the home and
  AWS substrates. It runs on a durable PV alongside the MinIO PV, preserved across cluster wipes:
  `vault init` runs exactly once (first time the PV is empty) and every subsequent
  `prodbox cluster reconcile` redeploys the chart against existing data and only unseals it, so
  Vault KV is as durable across rebuilds as any retained PV (see
  [storage_lifecycle_doctrine.md](./storage_lifecycle_doctrine.md)). This in-cluster Vault
  platform component has a Sprint 3.17 code-owned foundation. See
  [vault_doctrine.md §5](./vault_doctrine.md#5-vault-deployment-model).
- **Chart workloads consume Vault-held secrets via Vault Kubernetes auth only.** Chart workloads —
  including Keycloak — that need a secret authenticate through Vault Kubernetes auth: a workload
  service account, a namespace + SA-bound Vault role, and a least-privilege policy, surfaced via
  the Vault Agent Injector, the CSI Secret Store Vault provider, or app-side auth. There is no
  Secret-mounted plaintext Dhall fragment and no `SecretRef.FileSecret` arm; sensitive config
  fields are typed `SecretRef.Vault` references resolved against Vault at runtime. The Sprint
  3.18 foundation now has the typed chart-secret inventory, generated Vault policies/roles, and
  explicit ServiceAccounts for the straightforward chart controllers, and `vault reconcile` seeds
  generated/static KV objects after configuring the Kubernetes auth backend. The `websocket`
  workload uses this path today for its OIDC client secret; Keycloak, MinIO, VS Code, Gateway
  Runtime, Bootstrap Broker, Lifecycle Authority, Target Secret Agent, Patroni, and host/admin
  flows use separate Vault-backed materialization or direct Vault reads under distinct roles. The
  Vault chart binds its own ServiceAccount to `system:auth-delegator` for TokenReview. Sprint
  3.19 removed the old derivation and generated-secret paths around this model. See
  [vault_doctrine.md §12](./vault_doctrine.md#12-in-cluster-service-auth).
- **A sealed Vault fails secret-dependent startup closed.** When Vault is sealed, Keycloak
  bootstrap and other secret-dependent Pod startup fail closed; new Pods do not reconstruct secrets
  from any non-Vault source — there is no plaintext fallback. Sprint 3.18 pins the code-owned
  structural proof; Sprint 5.8 owns the live whole-system sealed-Vault validation. See
  [vault_doctrine.md §15](./vault_doctrine.md#15-sealed-state-behavior-matrix).

## 11. Planning Ownership

This document is normative chart-platform doctrine only.

Delivery sequencing, completion status, remaining work, and cleanup ownership are owned by
[../../DEVELOPMENT_PLAN/README.md](../../DEVELOPMENT_PLAN/README.md).

## Cross-References

- [Lifecycle Control-Plane Architecture](./lifecycle_control_plane_architecture.md)
- [CLI Command Surface](./cli_command_surface.md)
- [Envoy Gateway Edge Doctrine](./envoy_gateway_edge_doctrine.md)
- [Storage Lifecycle Doctrine](./storage_lifecycle_doctrine.md)
- [Local Registry Pipeline](./local_registry_pipeline.md)
- [Vault Secret-Management Doctrine](./vault_doctrine.md)
- [Development Plan](../../DEVELOPMENT_PLAN/README.md)
- [Documentation Standards](../documentation_standards.md)
