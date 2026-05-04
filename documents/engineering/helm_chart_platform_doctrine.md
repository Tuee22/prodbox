# Helm Chart Platform Doctrine

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [../../README.md](../../README.md),
[../../METALLB_ENVOY_KEYCLOAK_REDIS_WEBSOCKETS.md](../../METALLB_ENVOY_KEYCLOAK_REDIS_WEBSOCKETS.md),
[../../DEVELOPMENT_PLAN/README.md](../../DEVELOPMENT_PLAN/README.md), [README.md](./README.md),
[cli_command_surface.md](./cli_command_surface.md),
[envoy_gateway_edge_doctrine.md](./envoy_gateway_edge_doctrine.md),
[storage_lifecycle_doctrine.md](./storage_lifecycle_doctrine.md)

> **Purpose**: Define the singleton chart identity, namespace isolation, external Patroni
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
2. No repo-owned chart may render or own an embedded PostgreSQL subchart.
3. Helm-managed application PostgreSQL is namespace-local and Patroni-based: the internal
   `keycloak-postgres` release renders a `pgv2.percona.com/v2` `PerconaPGCluster` resource in the
   root chart namespace, and the cluster-wide Percona operator reconciles it.
4. `keycloak` depends on that namespace-local Patroni cluster.
5. `vscode` depends on `keycloak`, does not talk directly to PostgreSQL, and targets an
   Envoy-authenticated public browser path rather than a permanent app-local nginx auth proxy.
6. `api` runs from the shared `prodbox-public-edge-workload` image and targets the shared-host
   JWT-protected `/api` route.
7. `websocket` runs from the shared `prodbox-public-edge-workload` image, depends on the internal
   `redis` release for shared state, owns workload-managed OIDC bootstrap on `/ws/oidc`, and
   targets the shared-host JWT-protected `/ws` route.
8. Chart deploy fails fast until the cluster-wide Patroni platform exists. The actionable recovery
   path is `prodbox rke2 install`.

## 2. Singleton Chart Identity Rule

One Helm release per chart name exists cluster-wide at any time.

- Before deployment, the Haskell runtime inspects `helm list --all-namespaces`.
- If any release in the plan already exists, the entire deploy is rejected before Helm mutate
  operations begin.
- Reinstall requires an explicit `prodbox charts delete <chart>` first.

## 3. Root-Chart-Owned Namespace Rule

The namespace for a root chart stack equals the root chart name.

- `prodbox charts deploy gateway` deploys into the `gateway` namespace.
- `prodbox charts deploy keycloak` deploys `keycloak-postgres` plus `keycloak` into the
  `keycloak` namespace.
- `prodbox charts deploy vscode` deploys `keycloak-postgres`, `keycloak`, and `vscode` into the
  `vscode` namespace.
- `prodbox charts deploy api` deploys `api` into the `api` namespace.
- `prodbox charts deploy websocket` deploys `redis` plus `websocket` into the `websocket`
  namespace.

Repo-owned chart templates do not render resources into foreign namespaces. The only cluster-wide
dependency is the lifecycle-owned Percona PostgreSQL operator in the `postgres-operator`
namespace.

## 4. Patroni PostgreSQL Dependency Contract

The application database is not an embedded subchart. It is a separate Helm-managed release in the
same namespace as the consuming chart stack.

The supported contract is:

- `prodbox rke2 install` installs the cluster-wide `percona/pg-operator` Helm release into the
  `postgres-operator` namespace.
- `prodbox charts deploy keycloak` and `prodbox charts deploy vscode` include the internal
  `keycloak-postgres` release before `keycloak`.
- Each Patroni cluster runs exactly three PostgreSQL replicas.
- Patroni synchronous replication is enabled with strict mode.
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
3. PV names are deterministic.
4. `manual` is the only supported `StorageClass`.
5. `vscode` remains single-replica retained storage on the supported path.

Retained non-PV chart state lives separately under `.prodbox-state/<namespace>/`.

## 7. Delete Semantics

`prodbox charts delete <chart>`:

1. calls `helm uninstall` for each release in reverse dependency order
2. deletes Percona PostgreSQL pods and PVCs by selector in the root-chart namespace
3. deletes deterministic retained PVs
4. deletes the root-chart namespace
5. preserves `.data/` and `.prodbox-state/` on disk

This means a later deploy can rebind to the same retained host state.

## 8. Supported Charts

The chart registry is defined in `src/Prodbox/Lib/ChartPlatform.hs`.

| Chart | Kind | Dependencies | External Requirements | Storage | Public Host Required |
|-------|------|--------------|-----------------------|---------|----------------------|
| `keycloak-postgres` | internal | none | Patroni platform | 3 x 20Gi | no |
| `redis` | internal | none | none | none | no |
| `keycloak` | root | `keycloak-postgres` | none beyond dependency | none | yes |
| `vscode` | root | `keycloak` | none beyond dependency chain | 50Gi | yes |
| `api` | root | none | none beyond shared edge prerequisites | none | yes |
| `websocket` | root | `redis` | none beyond shared edge prerequisites | none | yes |
| `gateway` | root | none | none | none | yes |

Root charts:

- `gateway` deploys the in-cluster distributed gateway stack into the `gateway` namespace.
- `keycloak` deploys `keycloak-postgres` plus `keycloak` into the `keycloak` namespace.
- `vscode` deploys `keycloak-postgres`, `keycloak`, and `vscode` into the `vscode` namespace.
- `api` deploys the JWT-protected public API workload into the `api` namespace.
- `websocket` deploys the Redis-backed public WebSocket workload into the `websocket` namespace.

## 9. Supported Public Auth Model For `vscode`

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

- `vscode` uses Envoy-managed browser OIDC enforcement through `SecurityPolicy`.
- `api` uses Envoy-local JWT validation plus route-claim authorization through `SecurityPolicy`.
- `websocket` uses workload-managed OIDC bootstrap and cookie-backed session ownership on
  `/ws/oidc`, Envoy-local JWT validation plus route-claim authorization on `/ws`, Redis-backed
  reconnect-safe workload state, and readiness-based drain for live upgraded connections.
- `keycloak` stays on the shared public hostname under `/auth` and publicly exposes only the
  identity-route surfaces the shipped browser and workload-managed OIDC flows require.
- Public API and WebSocket workloads still follow the same public-edge doctrine and do not add
  chart-local auth proxies or a parallel ingress model.

The canonical public-edge doctrine and Redis, JWT, or WebSocket guidance live in
[Envoy Gateway Edge Doctrine](./envoy_gateway_edge_doctrine.md).

## 10. Required Settings and Auto-Generated Secrets

The following repository configuration values are required for the supported public workload
catalog:

| Setting | Purpose |
|---------|---------|
| `domain.demo_fqdn` | Canonical shared public hostname for `/auth`, `/vscode`, `/api`, `/ws`, `/harbor`, and `/minio` |

Namespace-local chart secrets live in `.prodbox-state/<namespace>/.secrets.json`:

| Secret | Purpose |
|--------|---------|
| `keycloak_admin_password` | Keycloak admin credentials |
| `keycloak_vscode_client_secret` | Envoy Gateway OIDC client secret for the protected `vscode` route |
| `keycloak_api_client_secret` | Envoy JWT client secret contract for the protected `api` route |
| `keycloak_websocket_client_secret` | WebSocket workload OIDC client secret and Envoy JWT client contract for the protected `websocket` route |
| `keycloak_demo_user_password` | Demo-user password consumed by the external API and WebSocket validations |
| `patroni_app_password` | retained Patroni application-user password for the namespace-local cluster |
| `patroni_superuser_password` | retained Patroni `postgres` superuser password for the namespace-local cluster |
| `patroni_standby_password` | retained Patroni standby-user password for the namespace-local cluster |

The chart platform renders the three corresponding Kubernetes secrets before the Patroni cluster
resource so retained PVC rebinding does not rotate credentials underneath preserved PostgreSQL
data. The rendered Kubernetes secret names are:

- `prodbox-<root-chart>-pg-pguser-keycloak`
- `prodbox-<root-chart>-pg-pguser-postgres`
- `prodbox-<root-chart>-pg-primaryuser`

When `api` or `websocket` deploy as separate root charts, the chart platform reuses the shared
`keycloak_*` values from `.prodbox-state/vscode/.secrets.json` so the shared-host Keycloak
client contracts stay aligned across the shipped public workloads.

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
