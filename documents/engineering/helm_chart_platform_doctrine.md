# Helm Chart Platform Doctrine

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: documents/engineering/README.md, documents/engineering/cli_command_surface.md, documents/engineering/storage_lifecycle_doctrine.md

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

## 7. `.data/<namespace>/<statefulset>/<ordinal>` Host-Path Contract

Retained host storage for chart workloads lives at:

```
<repo-root>/.data/<namespace>/<statefulset>/<ordinal>/
```

For example, `keycloak-postgres` in the `vscode` namespace:

```
.data/vscode/keycloak-postgres/0/
```

Rules:

1. The CLI creates host directories with `mkdir -p` before applying storage manifests.
2. `.data/` is excluded from both `.gitignore` and `.dockerignore`.
3. PV names are deterministic: `prodbox-chart-<namespace>-<statefulset>-<ordinal>`.
4. The `StorageClass` `prodbox-chart-null-storage` is used for all chart PVs (no-provisioner, Retain policy).

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

---

## 10. Required Settings

The following settings from `src/prodbox/settings.py` are required for chart deployment:

| Setting | Purpose |
|---------|---------|
| `VSCODE_FQDN` | Public FQDN for VS Code and Keycloak |
| `KEYCLOAK_ADMIN_PASSWORD` | Keycloak admin credentials |
| `KEYCLOAK_POSTGRES_PASSWORD` | PostgreSQL database password |
| `KEYCLOAK_OAUTH2_CLIENT_SECRET` | oauth2-proxy client secret |
| `VSCODE_OAUTH2_PROXY_COOKIE_SECRET` | oauth2-proxy cookie signing secret |
| `GOOGLE_OAUTH_CLIENT_ID` | Google IdP OAuth2 client ID |
| `GOOGLE_OAUTH_CLIENT_SECRET` | Google IdP OAuth2 client secret |

---

## 11. Delivery Evidence

Chart platform delivery was completed on 2026-03-28 through Sprints 5–9.

### Sprint 5 – Contracts and scaffolding
- `helm_chart_platform_doctrine.md` (this document) written and linked
- `documents/engineering/cli_command_surface.md` updated with `charts` command group
- `.gitignore` and `.dockerignore` updated with `.data/`

### Sprint 6 – CLI integration
- `src/prodbox/cli/effects.py`: `ChartListEffect`, `ChartStatusEffect`, `ChartDeployEffect`, `ChartDeleteEffect`
- `src/prodbox/cli/command_adt.py`: `ChartListCommand`, `ChartStatusCommand`, `ChartDeployCommand`, `ChartDeleteCommand`
- `src/prodbox/cli/dag_builders.py`: chart DAG builders wired to plan builders
- `src/prodbox/cli/interpreter.py`: `_interpret_chart_*` handlers
- `src/prodbox/cli/charts.py`: thin Click wrappers
- `src/prodbox/cli/main.py`: `charts` group registered
- `src/prodbox/cli/test_cmd.py`: `charts-storage`, `charts-platform`, `charts-vscode` named suites

### Sprint 7 – Storage tests
- `tests/unit/test_chart_platform.py`: pure-function tests for `_storage_binding`, plan builders, delete semantics
- `tests/integration/test_charts_storage.py`: deploy → verify PV/PVC → delete → verify host dirs preserved → redeploy → verify same names

### Sprint 8 – vscode stack end-to-end
- `charts/` audited: all charts have pinned versions, NetworkPolicy manifests, no PV/PVC templates, same-namespace service refs
- `tests/unit/test_chart_platform.py` extended with prerequisite ordering and same-namespace-only tests
- `tests/integration/test_charts_platform.py`: all three releases deploy into `vscode` namespace, singleton enforcement, delete cleans up cleanly

### Sprint 9 – Public hostname and closure
- `tests/integration/test_charts_vscode.py`: HTTPS reachability, TLS issuer (Let's Encrypt), auth redirect, Google OAuth upstream
- `README.md` updated with `prodbox charts` public command summary
- `DEVELOPMENT_COMPLETION_PLAN.md` sprints 5–9 marked complete

### Verification command
```bash
poetry run prodbox check-code
poetry run prodbox test unit
```

## Cross-References

- [CLI Command Surface](./cli_command_surface.md)
- [Storage Lifecycle Doctrine](./storage_lifecycle_doctrine.md)
- [Effectful DAG Architecture](./effectful_dag_architecture.md)
- [Unit Testing Policy](./unit_testing_policy.md)
- [Documentation Standards](../documentation_standards.md)
