# Helm Chart Platform Doctrine

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: README.md, DEVELOPMENT_PLAN/README.md, documents/engineering/README.md, documents/engineering/cli_command_surface.md, documents/engineering/storage_lifecycle_doctrine.md

> **Purpose**: Define the singleton chart identity, namespace isolation, storage lifecycle, and delete semantics for the `prodbox charts` command platform.

---

## 1. Canonical Doctrine Statements

The chart platform deploys bespoke Helm charts through the standard Click → ADT → eDAG → interpreter pipeline. Each root chart owns a namespace equal to its name and manages all prerequisite charts within that namespace.

---

## 2. Singleton Chart Identity Rule

One Helm release per chart name exists cluster-wide at any time.

- Before any deployment, `deploy_chart_plan()` calls `helm list --all-namespaces` and asserts no release in the plan is already installed.
- If any duplicate release is detected, the entire deploy is rejected before any Helm action.
- Reinstalling a chart requires an explicit `prodbox charts delete <chart>` first.

---

## 3. Root-Chart-Owned Namespace Rule

The namespace for a root chart stack equals the root chart name.

- `prodbox charts deploy vscode` deploys into the `vscode` namespace.
- All prerequisite charts (e.g. `keycloak`, `keycloak-postgres`) are co-deployed into the same `vscode` namespace.
- No chart template may render resources into a foreign namespace.

---

## 4. Same-Namespace-Only Prerequisite Composition

All charts within a root stack share one namespace. Cross-namespace service references are prohibited.

- Service names are unqualified (e.g. `keycloak-postgres`, not `keycloak-postgres.vscode.svc.cluster.local`).
- NetworkPolicy rules deny ingress/egress to/from other namespaces by default.

---

## 5. Default-Deny Network Policy Isolation

Every bespoke chart must include a `NetworkPolicy` that:

1. Denies all ingress by default.
2. Allows ingress only from pods within the same namespace (matching `prodbox.io/chart-root` label).
3. Allows ingress from the ingress controller namespace for charts with an `Ingress` resource.

---

## 6. CLI-Owned PV/PVC Lifecycle

Charts never create `PersistentVolume` or `PersistentVolumeClaim` objects.

- The CLI creates PV and PVC objects before calling Helm, using deterministic names derived from the namespace and statefulset.
- Charts reference existing PVCs via `existingClaim` values.
- This guarantees PV/PVC rebinding survives delete/redeploy cycles without data loss.

---

## 7. `.data/<namespace>/<release>/<workload>/<ordinal>/<claim>` Host-Path Contract

Retained host storage for chart workloads lives at:

```
<repo-root>/.data/<namespace>/<release>/<workload>/<ordinal>/<claim>/
```

For example, `keycloak-postgres` in the `vscode` namespace:

```
.data/vscode/keycloak-postgres/keycloak-postgres/0/data/
```

Rules:

1. The CLI creates host directories with `mkdir -p` before applying storage manifests.
2. `.data/` is excluded from both `.gitignore` and `.dockerignore`.
3. PV names are deterministic: `prodbox-chart-<namespace>-<release>-<workload>-<ordinal>-<claim>`.
4. The `StorageClass` `manual` (provisioner `kubernetes.io/no-provisioner`, Retain policy) is the only permitted StorageClass; bootstrap fails if a chart requests a dynamic provisioner.
5. All stateful services deploy in HA mode (multiple replicas with pod anti-affinity) by default; dev mode (`PRODBOX_DEV_MODE=true`) suppresses anti-affinity but retains replica counts.

---

## 8. Delete Semantics

`prodbox charts delete <chart>`:

1. Calls `helm uninstall` for each release in reverse dependency order.
2. Deletes all CLI-created PVCs in the chart namespace.
3. Deletes all CLI-created PVs (cluster-scoped).
4. Deletes the namespace (which garbage-collects remaining namespace-scoped resources).
5. **Never deletes `.data/` host directories** — data is always preserved on disk.

This means a subsequent `prodbox charts deploy <chart>` will rebind to the same host paths with new PV/PVC objects.

---

## 9. Supported Charts

The chart registry is defined in `src/prodbox/lib/chart_platform.py`. Current charts:

| Chart | Dependencies | Storage | Public Host Required |
|-------|-------------|---------|---------------------|
| `keycloak-postgres` | none | 20Gi | no |
| `keycloak` | `keycloak-postgres` | none | yes |
| `vscode` | `keycloak` | 50Gi | yes |

Root charts:

- `vscode` — deploys `keycloak-postgres`, `keycloak`, and `vscode` into the `vscode` namespace.

## 10. Supported Auth Model For `vscode`

The `vscode` chart stack supports one auth model only:

1. nginx handles the OIDC authorization-code flow.
2. Keycloak uses its local user database and serves the login page under `/auth`.
3. code-server is reachable only behind the nginx auth wall.

Unsupported legacy paths:

- `oauth2-proxy`
- Google OAuth as the supported identity-provider path
- Standalone local `docker-compose` delivery paths outside `prodbox charts`

---

## 11. Required Settings and Auto-Generated Secrets

The following setting from `src/prodbox/settings.py` is required for chart deployment:

| Setting | Purpose |
|---------|---------|
| `VSCODE_FQDN` | Public FQDN for VS Code and Keycloak |

Cluster-internal secrets are auto-generated at chart deploy time and persisted in
`.data/<namespace>/.secrets.json`. They are not configured via `.env`:

| Secret | Purpose |
|--------|---------|
| `keycloak_admin_password` | Keycloak admin credentials |
| `keycloak_postgres_password` | PostgreSQL database password |
| `keycloak_nginx_client_secret` | nginx OIDC client secret (registered in Keycloak as `vscode-nginx`) |

---

## 12. Planning Ownership

This document is normative chart-platform doctrine only.

Delivery sequencing, completion status, remaining work, and legacy-path removal
are owned by
[DEVELOPMENT_PLAN/README.md](../../DEVELOPMENT_PLAN/README.md).

Canonical repository facts referenced by this doctrine:

1. `prodbox charts` is the only supported chart-lifecycle entrypoint.
2. The supported auth path for `vscode` is nginx OIDC plus local Keycloak users.
3. There is no separate repository-supported `docker/vscode-dev` flow for `vscode`.
4. Public-host closure and any remaining cleanup refactors must be tracked in
   [DEVELOPMENT_PLAN/README.md](../../DEVELOPMENT_PLAN/README.md), not in this doctrine
   document.

## Cross-References

- [CLI Command Surface](./cli_command_surface.md)
- [Storage Lifecycle Doctrine](./storage_lifecycle_doctrine.md)
- [Effectful DAG Architecture](./effectful_dag_architecture.md)
- [Unit Testing Policy](./unit_testing_policy.md)
- [Development Plan](../../DEVELOPMENT_PLAN/README.md)
- [Documentation Standards](../documentation_standards.md)
