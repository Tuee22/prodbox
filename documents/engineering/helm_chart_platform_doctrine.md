# Helm Chart Platform Doctrine

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [../../README.md](../../README.md), [../../DEVELOPMENT_PLAN/README.md](../../DEVELOPMENT_PLAN/README.md), [README.md](./README.md), [cli_command_surface.md](./cli_command_surface.md), [storage_lifecycle_doctrine.md](./storage_lifecycle_doctrine.md)

> **Purpose**: Define the singleton chart identity, namespace isolation, external Patroni
> PostgreSQL dependency model, storage lifecycle, and delete semantics for `prodbox charts`.

## 1. Canonical Doctrine Statements

The chart platform is owned by the native Haskell runtime in:

- `src/Prodbox/CLI/Charts.hs`
- `src/Prodbox/Lib/ChartPlatform.hs`
- `src/Prodbox/Lib/Storage.hs`

The supported chart doctrine is:

1. `prodbox charts` manages only the repo-owned root charts `gateway`, `keycloak`, and `vscode`.
2. No repo-owned chart may render or own an embedded PostgreSQL subchart.
3. Helm-managed application PostgreSQL is namespace-local and Patroni-based: the internal
   `keycloak-postgres` release renders an `acid.zalan.do/v1` `postgresql` resource in the root
   chart namespace, and the cluster-wide `postgres-operator` reconciles it.
4. `keycloak` depends on that namespace-local Patroni cluster. `vscode` depends on `keycloak` and
   does not talk directly to PostgreSQL.
5. Chart deploy fails fast until the cluster-wide Patroni platform exists. The actionable recovery
   path is `./.build/prodbox rke2 install`.

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

Repo-owned chart templates do not render resources into foreign namespaces. The only cluster-wide
dependency is the lifecycle-owned Patroni operator in the `postgres-operator` namespace.

## 4. Patroni PostgreSQL Dependency Contract

The application database is not an embedded subchart. It is a separate Helm-managed release in the
same namespace as the consuming chart stack.

The supported contract is:

- `prodbox rke2 install` installs the cluster-wide `postgres-operator` Helm release into the
  `postgres-operator` namespace.
- `prodbox charts deploy keycloak` and `prodbox charts deploy vscode` include the internal
  `keycloak-postgres` release before `keycloak`.
- Each Patroni cluster runs exactly three PostgreSQL replicas.
- Patroni synchronous replication is enabled with strict mode.
- The PostgreSQL workload image is Harbor-backed `spilo-17`.
- Keycloak consumes the operator-generated credentials secret
  `keycloak.prodbox-<root-chart>-postgres.credentials.postgresql.acid.zalan.do`.
- The primary service endpoint is
  `prodbox-<root-chart>-postgres.<namespace>.svc.cluster.local`.

The chart runtime validates the platform prerequisite by requiring both:

- CRD `postgresqls.acid.zalan.do`
- deployment `postgres-operator` in namespace `postgres-operator`

before any chart that depends on PostgreSQL is deployed.

## 5. CLI-Owned PV/PVC Lifecycle

Repo-owned charts never create `PersistentVolume` or `PersistentVolumeClaim` objects directly.

- The Haskell CLI creates PV and PVC objects before Helm runs.
- Charts consume those claims through deterministic rendered values.
- This keeps rebinding deterministic across delete and reinstall cycles.

This rule applies to the internal `keycloak-postgres` release as well. There is no Pulumi-owned
PostgreSQL exception on the supported path.

## 6. `.data/<namespace>/<release>/<workload>/<ordinal>/<claim>` Host-Path Contract

Chart-owned retained host storage lives at:

```text
<repo-root>/.data/<namespace>/<release>/<workload>/<ordinal>/<claim>/
```

Examples:

- `keycloak-postgres` for the `keycloak` root chart:
  `.data/keycloak/keycloak-postgres/prodbox-keycloak-postgres/0/data/`
- `keycloak-postgres` for the `vscode` root chart:
  `.data/vscode/keycloak-postgres/prodbox-vscode-postgres/0/data/`
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
2. deletes CLI-created PVCs in the root-chart namespace
3. deletes CLI-created PVs
4. deletes the root-chart namespace
5. preserves `.data/` and `.prodbox-state/` on disk

This means a later deploy can rebind to the same retained host state.

## 8. Supported Charts

The chart registry is defined in `src/Prodbox/Lib/ChartPlatform.hs`.

| Chart | Kind | Dependencies | External Requirements | Storage | Public Host Required |
|-------|------|--------------|-----------------------|---------|----------------------|
| `keycloak-postgres` | internal | none | Patroni platform | 3 x 20Gi | no |
| `keycloak` | root | `keycloak-postgres` | none beyond dependency | none | yes |
| `vscode` | root | `keycloak` | none beyond dependency chain | 50Gi | yes |
| `gateway` | root | none | none | none | yes |

Root charts:

- `gateway` deploys the in-cluster distributed gateway stack into the `gateway` namespace.
- `keycloak` deploys `keycloak-postgres` plus `keycloak` into the `keycloak` namespace.
- `vscode` deploys `keycloak-postgres`, `keycloak`, and `vscode` into the `vscode` namespace.

## 9. Supported Auth Model For `vscode`

The supported `vscode` auth path is:

1. nginx handles the OIDC authorization-code flow
2. Keycloak serves the login page under `/auth`
3. code-server is reachable only behind the nginx auth wall
4. Keycloak stores its data in the namespace-local Patroni cluster for the root chart
5. supported image refs are Harbor-only for `keycloak`, `vscode-nginx`, `code-server`,
   `postgres-operator`, and `spilo` after Harbor bootstrap

Unsupported legacy paths remain:

- embedded PostgreSQL chart subcomponents
- shared `pgpool` or `repmgr` service dependencies
- standalone local `docker-compose` delivery outside `prodbox charts`

## 10. Required Settings and Auto-Generated Secrets

The following repository configuration value is required for the public `vscode` path:

| Setting | Purpose |
|---------|---------|
| `domain.vscode_fqdn` | Public FQDN for VS Code and Keycloak ingress |

Namespace-local chart secrets live in `.prodbox-state/<namespace>/.secrets.json`:

| Secret | Purpose |
|--------|---------|
| `keycloak_admin_password` | Keycloak admin credentials |
| `keycloak_nginx_client_secret` | nginx OIDC client secret |
| `patroni_app_password` | retained Patroni application-user password for the namespace-local cluster |
| `patroni_superuser_password` | retained Patroni `postgres` superuser password for the namespace-local cluster |
| `patroni_standby_password` | retained Patroni standby-user password for the namespace-local cluster |

The chart platform renders the three corresponding Kubernetes secrets before the Patroni cluster
resource so retained PVC rebinding does not rotate credentials underneath preserved PostgreSQL
data.

## 11. Planning Ownership

This document is normative chart-platform doctrine only.

Delivery sequencing, completion status, remaining work, and cleanup ownership are owned by
[../../DEVELOPMENT_PLAN/README.md](../../DEVELOPMENT_PLAN/README.md).

## Cross-References

- [CLI Command Surface](./cli_command_surface.md)
- [Storage Lifecycle Doctrine](./storage_lifecycle_doctrine.md)
- [Local Registry Pipeline](./local_registry_pipeline.md)
- [Development Plan](../../DEVELOPMENT_PLAN/README.md)
- [Documentation Standards](../documentation_standards.md)
