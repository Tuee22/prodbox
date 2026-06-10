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
[secret_derivation_doctrine.md](./secret_derivation_doctrine.md),
[storage_lifecycle_doctrine.md](./storage_lifecycle_doctrine.md),
[unit_testing_policy.md](./unit_testing_policy.md)
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
   Public `status|deploy|delete` inputs are restricted to those root chart names; the internal
   dependency releases are runtime-owned and are not supported public CLI targets.
2. No repo-owned chart may render or own an embedded PostgreSQL subchart.
3. Helm-managed application PostgreSQL is namespace-local and Patroni-based: the internal
   `keycloak-postgres` release renders a `pgv2.percona.com/v2` `PerconaPGCluster` resource in the
   root chart namespace, and the cluster-wide Percona operator reconciles it.
4. `keycloak` depends on that namespace-local Patroni cluster.
5. `vscode` depends on `keycloak`, does not talk directly to PostgreSQL, targets an
   Envoy-authenticated public browser path rather than a permanent app-local nginx auth proxy,
   and keeps Envoy's OIDC provider token exchange on the namespace-local `keycloak` Service.
6. `api` runs from the shared `prodbox-public-edge-workload` image, keeps its workload resources
   namespace-local in `api`, and targets the shared-host JWT-protected `/api` route by attaching
   to the shared `public-edge` `Gateway` published from the `vscode` namespace. Envoy validates
   JWTs against the public issuer but fetches JWKS through an in-cluster backchannel to
   `keycloak.vscode.svc.cluster.local`.
7. `websocket` runs from the shared `prodbox-public-edge-workload` image, keeps its workload and
   `redis` resources namespace-local in `websocket`, owns workload-managed OIDC bootstrap on
   `/ws/oidc`, targets the shared-host JWT-protected `/ws` route by attaching to the shared
   `public-edge` `Gateway` in `vscode`, and currently exchanges tokens through a private in-cluster
   backchannel to `keycloak.vscode.svc.cluster.local`. Envoy's JWT JWKS fetch uses the same
   in-cluster Keycloak service boundary.
8. The current supported shared public edge is anchored in the `vscode` namespace, where the chart
   platform publishes the shared `Gateway`, listener certificate, and `/auth` Keycloak identity
   route consumed by the shipped browser, API, WebSocket, Harbor, and MinIO surfaces.
9. The shared `Gateway` renders a port `80` HTTP listener only for the redirect-only `HTTPRoute`
   named `public-edge-http-redirect`; all backend routes attach to HTTPS listener sections and the
   chart platform does not render plaintext application forwarding.
10. Chart deploy fails fast until the cluster-wide Patroni platform exists. The actionable recovery
   path is `prodbox rke2 reconcile`.
11. Chart templates that consume the canonical public-edge path catalog do so through the
    marker-delimited generated `route-registry` blocks maintained by `prodbox docs generate`,
    not through hand-maintained inline route inventories.
12. Chart metadata is doctrine-owned: every chart helper exports
    `app.kubernetes.io/name`, `app.kubernetes.io/managed-by: prodbox`, and
    `prodbox.io/chart-root`, and `prodbox lint chart` validates those invariants together with
    `Chart.yaml` metadata.
13. Keycloak's NetworkPolicy keeps explicit egress: PostgreSQL, in-namespace Keycloak service
    traffic, cluster DNS, external HTTPS for issuer/OIDC paths, and the configured SMTP port from
    `.Values.smtp.port` for SES-backed invite email.

## 1A. Chart Lint and Route Inventory Generation

The supported chart-maintenance surface is split between `prodbox lint chart` and
`prodbox docs generate`.

- `prodbox lint chart` validates every chart under `charts/` for the canonical
  `Chart.yaml` metadata fields (`apiVersion: v2`, `name`, `version`, `appVersion`), the
  required chart-label helper lines, and drift on the generated `route-registry` sections.
- `prodbox docs generate` refreshes the marker-delimited route inventory consumed by:
  - `charts/keycloak/templates/gateway.yaml`
  - `charts/vscode/templates/http-route.yaml`
  - `charts/api/templates/http-route.yaml`
  - `charts/websocket/templates/http-route.yaml`
- The generated route inventory is derived from `src/Prodbox/PublicEdge.hs`, so the public
  path catalog stays synchronized across docs, chart manifests, and validation surfaces.

## 2. Singleton Chart Identity Rule

One Helm release per chart name exists cluster-wide at any time.

- Before deployment, the Haskell runtime inspects `helm list --all-namespaces`.
- If any release in the plan already exists, `prodbox charts deploy <chart>` reports the current
  deployment surface as success and performs no Helm or storage mutation.
- Resetting the chart stack still requires an explicit `prodbox charts delete <chart>` first.

## 3. Root-Chart Workload Namespace and Shared Public-Edge Attachment Rule

The root chart name still determines the owning workload namespace for chart-local resources, but
the current supported public edge is shared.

- `prodbox charts deploy gateway` deploys into the `gateway` namespace.
- `prodbox charts deploy keycloak` deploys `keycloak-postgres` plus `keycloak` into the
  `keycloak` namespace.
- `prodbox charts deploy vscode` deploys `keycloak-postgres`, `keycloak`, and `vscode` into the
  `vscode` namespace and publishes the shared `public-edge` `Gateway`, the HTTPS listener
  certificate, the redirect-only HTTP listener and route, and the `/auth` Keycloak route used by
  the supported shared-host edge and the authenticated `prodbox users` invite API.
- `prodbox charts deploy api` deploys its workload and JWT `SecurityPolicy` into the `api`
  namespace, then attaches its `HTTPRoute` to the shared `public-edge` `Gateway` in `vscode`
  through a cross-namespace `parentRef`.
- `prodbox charts deploy websocket` deploys `redis`, its workload, and JWT `SecurityPolicy` into
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
Controller on EKS) and Route 53 hosting. Substrate equivalence is enforced as a structural
invariant, not maintained by parallel hand-edited installers (Sprint 7.12):

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
   (Harbor, MinIO, the Percona PostgreSQL operator, MetalLB-or-ALB-controller, Envoy Gateway,
   cert-manager). A coverage test asserts both installers cover every entry — it is **not** a
   unified step DAG; each substrate keeps its own ordering, but neither may silently drop a
   component the other installs. The AWS substrate is **not** a "no-Harbor" cluster.

This is the chart-platform-side statement of the substrate-equivalence doctrine in
[../../CLAUDE.md](../../CLAUDE.md) "Substrate Equivalence" and
[../../DEVELOPMENT_PLAN/substrates.md](../../DEVELOPMENT_PLAN/substrates.md). When AWS appears to
be "missing" a platform piece the home cluster has, the fix is to extend the shared inventory and
the AWS installer, never to render different image refs or re-pin versions per substrate.

## 4. Patroni PostgreSQL Dependency Contract

The application database is not an embedded subchart. It is a separate Helm-managed release in the
same namespace as the consuming chart stack.

The supported contract is:

- `prodbox rke2 reconcile` installs the cluster-wide `percona/pg-operator` Helm release into the
  `postgres-operator` namespace.
- `prodbox charts deploy keycloak` and `prodbox charts deploy vscode` include the internal
  `keycloak-postgres` release before `keycloak`.
- Each Patroni cluster runs exactly three PostgreSQL replicas.
- Patroni synchronous replication is enabled across the supported three-replica steady state.
- The PostgreSQL workload images are Harbor-backed:
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

## 6. `.data/<namespace>/<release>/<workload>/<ordinal>/<claim>` Host-Path Contract

Chart-owned retained host storage lives at:

```text
<repo-root>/.data/<namespace>/<release>/<workload>/<ordinal>/<claim>/
```

Examples:

- `keycloak-postgres` for the `keycloak` root chart:
  `.data/keycloak/keycloak-postgres/prodbox-keycloak-pg/0/data/`
- `keycloak-postgres` for the `vscode` root chart:
  `.data/vscode/keycloak-postgres/prodbox-vscode-pg/0/data/`
- `vscode` StatefulSet:
  `.data/vscode/vscode/vscode/0/data/`

Rules:

1. The CLI creates host directories before storage manifests are applied.
2. `.data/` is reserved for PV contents only.
3. PV names are deterministic and flow through `src/Prodbox/Naming.hs`.
4. `manual` is the only supported `StorageClass`.
5. `vscode` remains single-replica retained storage on the supported path.

All non-PV chart state lives inside the cluster as native k8s Secrets and ConfigMaps.
No `prodbox` command writes to `.prodbox-state/`; the directory is removed from the
supported architecture and the `forbidDotProdboxState` lint in `prodbox check-code`
enforces this. Data-bound chart secrets (Patroni roles, Keycloak admin, gateway
peer-event keys) are derived from the master seed by the in-cluster gateway service per
[Secret Derivation Doctrine](./secret_derivation_doctrine.md). Non-data-bound chart
secrets are generated by Helm `lookup`-guarded `randAlphaNum` / `genSelfSignedCert`
helpers on first install and preserved by the same `lookup` early-return on subsequent
reconciles.

### Daemon and workload config mount contract

Every `prodbox`-launched in-cluster process (gateway daemon, workload Pods) takes its
runtime configuration from exactly one Dhall file at `--config`, per
[config_doctrine.md](./config_doctrine.md). The chart-side rendering of that surface
follows a uniform mount layout:

| Mount source | Mount path | Content |
|---|---|---|
| `<release>-config-<podId>` ConfigMap | `/etc/<release>/config.dhall` | per-Pod Dhall expression; imports the files below |
| `<release>-orders` ConfigMap (gateway only) | `/etc/gateway/orders.dhall` | cluster-wide ranked-node + timing Dhall expression |
| `<release>-secrets-<credClass>` Secret (one per credential class, e.g. `aws`, `minio`) | `/etc/<release>/secrets/<credClass>.dhall` | Dhall expression carrying the credential values, imported by the main Dhall via `as Text` to keep the value opaque to the typechecker |
| Cert-manager-issued per-Pod TLS Secret | `/tls/` | TLS keypair referenced by file path from the Dhall config |
| Cert-manager CA Secret | `/ca/` | trust anchor referenced by file path from the Dhall config |

The operator-facing ConfigMap holds no secret material — only references to the
Secret-mounted Dhall imports. ConfigMap and Secret volume updates land in the Pod via
the kubelet's atomic `..data` symlink swap; the daemon's file-watch reload trigger
follows that swap rather than the leaf-file `mtime`. The chart never injects daemon
configuration as environment variables; the only env vars on supported daemon Pods
carry k8s runtime metadata the binary does not read for config.

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
| `gateway` | root | none | none | none | yes |

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
5. Supported image refs are Harbor-only for `keycloak`, `code-server`, the Envoy Gateway public
   edge image set, the Percona operator, and the Percona PostgreSQL workload after Harbor
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
  long-lived `pulumi_state_backend` S3 bucket under the substrate-scoped key
  `public-edge-tls/<substrate>/<fqdn>`, and restored before every issuance on **all** rebuild
  paths — including a fresh cluster after `prodbox rke2 delete`, not only the
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
  for the lifecycle-class registration; the certificate is removed only by `prodbox nuke`.
- Public API and WebSocket workloads still follow the same public-edge doctrine and do not add
  chart-local auth proxies, extra public `Gateway` resources, or a parallel ingress model.

The canonical public-edge doctrine and Redis, JWT, or WebSocket guidance live in
[Envoy Gateway Edge Doctrine](./envoy_gateway_edge_doctrine.md).

## 10. Required Settings and Auto-Generated Secrets

The following repository configuration values are required for the supported public workload
catalog:

| Setting | Purpose |
|---------|---------|
| `domain.demo_fqdn` | Canonical shared public hostname for `/auth`, `/vscode`, `/api`, `/ws`, `/harbor`, and `/minio` |

Namespace-local chart secrets are k8s Secrets, partitioned by class per
[Secret Derivation Doctrine](./secret_derivation_doctrine.md) §6:

| Secret (logical key) | Rendered k8s Secret | Class | Source |
|---|---|---|---|
| `keycloak_admin_password` | `keycloak-runtime.admin` | derived | gateway service, context `keycloak:<ns>:admin` |
| `patroni_app_password` | `prodbox-<root-chart>-pg-pguser-keycloak` | derived | gateway service, context `patroni:<ns>:<release>:app` |
| `patroni_superuser_password` | `prodbox-<root-chart>-pg-pguser-postgres` | derived | gateway service, context `patroni:<ns>:<release>:superuser` |
| `patroni_standby_password` | `prodbox-<root-chart>-pg-primaryuser` | derived | gateway service, context `patroni:<ns>:<release>:standby` |
| `keycloak_vscode_client_secret` | `keycloak-runtime.vscodeClient` | chart-generated | Helm `lookup` + `randAlphaNum` |
| `keycloak_api_client_secret` | `keycloak-runtime.apiClient` | chart-generated | Helm `lookup` + `randAlphaNum` |
| `keycloak_websocket_client_secret` | `keycloak-runtime.websocketClient` | chart-generated | Helm `lookup` + `randAlphaNum` |
| `keycloak_demo_user_password` | `keycloak-runtime.demoUser` | chart-generated | Helm `lookup` + `randAlphaNum` |

The derived rows preserve credentials underneath preserved PostgreSQL data because the
master seed lives on MinIO's PV under `.data/minio/...` and survives cluster wipes. On
each `prodbox charts deploy <chart>` the chart-platform pre-install Job POSTs to
`/v1/secret/ensure-namespace` on the in-cluster gateway ClusterIP; the gateway
materializes the four derived Secrets above; Helm's `lookup` picks them up during the
main install. Chart-generated rows use the standard `lookup`-guarded `randAlphaNum`
idiom so re-deploys preserve the existing value.

When `api` or `websocket` deploy as separate root charts, the same gateway-service
derivation path runs for their namespaces and Helm `lookup` reads the shared
`keycloak_*` client values from `vscode`'s `keycloak-runtime` Secret as already
rendered. The `vscode` SecurityPolicy, API/WebSocket JWT `remoteJWKS` policies, and WebSocket
workload all keep provider/token/JWKS backchannels in-cluster (`keycloak` Service for
namespace-local VS Code; the shared `keycloak.vscode.svc.cluster.local:8080` endpoint for
separately deployed API/WebSocket) rather than depending on a second public identity surface or
public-load-balancer hairpin behavior. The host-side Harbor/MinIO admin routes use the same
public-edge rule: substrate-aware public issuer and redirect URLs, plus the shared internal
Keycloak token endpoint for Envoy's provider exchange. The AWS substrate platform installs those
admin routes after gateway MinIO bootstrap.

The gateway chart emits Namespace resources for cross-namespace RBAC targets such as `keycloak`
and `vscode`. If the invite SMTP sync must create those namespaces first so `keycloak-smtp` exists
before Keycloak's Helm `lookup`, the sync stamps the same Helm ownership metadata (`gateway`
release in the `gateway` namespace) and the gateway Namespace resources carry
`helm.sh/resource-policy: keep`. That keeps the pre-sync compatible with Helm adoption while
preventing gateway uninstall from deleting workload namespaces or retained SMTP Secrets. Existing
Keycloak realms are still patched by `prodbox users invite` from the same `keycloak-smtp` Secret
before invite sends, because realm import is first-create only.

## 11. Planning Ownership

This document is normative chart-platform doctrine only.

Delivery sequencing, completion status, remaining work, and cleanup ownership are owned by
[../../DEVELOPMENT_PLAN/README.md](../../DEVELOPMENT_PLAN/README.md).

## Cross-References

- [CLI Command Surface](./cli_command_surface.md)
- [Envoy Gateway Edge Doctrine](./envoy_gateway_edge_doctrine.md)
- [Storage Lifecycle Doctrine](./storage_lifecycle_doctrine.md)
- [Local Registry Pipeline](./local_registry_pipeline.md)
- [Development Plan](../../DEVELOPMENT_PLAN/README.md)
- [Documentation Standards](../documentation_standards.md)
