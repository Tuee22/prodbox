# File: DEVELOPMENT_PLAN/phase-4-lifecycle-canonical-paths.md
# Phase 4: Lifecycle Hardening and Canonical-Path Cleanup

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md), [system-components.md](system-components.md)

> **Purpose**: Capture the lifecycle hardening work that removes cleanup-settling retries and the
> canonical-path cleanup work that leaves one supported surface per major capability.

## Phase Summary

This phase hardens `rke2 cleanup` until lifecycle validation passes without settling retries, then
removes duplicate or compatibility-only runtime, CLI, validation, and tooling paths, closes
the remaining local edge-infrastructure automation gaps around MetalLB, Traefik, cert-manager,
always-on gateway supervision, explicit per-subdomain DNS continuity, and public-host diagnostics,
consolidates the retained storage model to one StorageClass, migrates the `.data/` path scheme
to 5 segments, adopts HA-mode deployment doctrine, and simplifies `.env` to carry only external
auth and non-secret configuration while moving cluster-internal secrets to auto-generated K8s
Secrets. All cleanup history remains centralized in
[legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md).

## Sprint 4.1: `rke2 cleanup` Hardening and Lifecycle Regression Closure ✅

**Status**: Done
**Implementation**: `src/prodbox/cli/rke2.py`, `src/prodbox/cli/interpreter.py`, `tests/integration/test_prodbox_lifecycle.py`
**Docs to update**: `documents/engineering/README.md`, `documents/engineering/integration_fixture_doctrine.md`, `documents/engineering/prerequisite_doctrine.md`, `documents/engineering/storage_lifecycle_doctrine.md`

### Objective

Make `rke2 cleanup` stable enough that the lifecycle suite does not need retry-based settling.

### Deliverables

- Namespace-first cleanup replaces the old multi-pass cleanup implementation.
- Retained kinds (`PersistentVolume`, `StorageClass`, `PersistentVolumeClaim`) are preserved by
  doctrine.
- The lifecycle suite proves first-attempt cleanup success and retained-storage rebinding without a
  cleanup-settling shim.

### Validation

1. `poetry run prodbox check-code`
2. `poetry run prodbox test unit`
3. `poetry run prodbox test integration lifecycle`

### Remaining Work

None.

## Sprint 4.2: Canonical-Path Cleanup and Legacy Removal ⏸️

**Status**: Blocked
**Implementation**: `src/prodbox/cli/gateway.py`, `src/prodbox/settings.py`, `src/prodbox/cli/summary.py`, `src/prodbox/lib/lint/`
**Blocked by**: external AWS Route 53 permissions are still required for the final `dns-aws`, `pulumi`, and `public-dns` proof reruns
**Docs to update**: `documents/engineering/README.md`, `documents/engineering/aws_integration_environment_doctrine.md`, `documents/engineering/cli_command_surface.md`, `documents/engineering/dependency_management.md`, `documents/engineering/distributed_gateway_architecture.md`, `documents/engineering/helm_chart_platform_doctrine.md`, `documents/engineering/prerequisite_doctrine.md`, `documents/engineering/unit_testing_policy.md`

### Objective

Collapse each major surface to one canonical runtime path, one canonical CLI path, and one
canonical automated validation path.

### Deliverables

- Compatibility-only or duplicate operator paths are removed instead of preserved.
- Doctrine docs remain architectural and current; transitional removal timing lives only in this
  plan suite.
- Workflow and tooling residue that conflicts with the supported operator doctrine is removed.
- The remaining legacy inventory contains only genuinely unresolved items.

### Validation

1. `poetry run prodbox check-code`
2. `poetry run prodbox test unit`
3. `poetry run prodbox test integration cli`
4. `poetry run prodbox test integration gateway-daemon`
5. `poetry run prodbox test integration gateway-pods`
6. `poetry run prodbox test integration charts-platform`
7. `poetry run prodbox test integration dns-aws`
8. `poetry run prodbox test integration pulumi`

### Current Validation State

- Repository-wide status tracking has been centralized in this plan suite.
- The `rke2_killall_exists` prerequisite has been removed.
- The legacy Poetry `daemon` entrypoint, compatibility container wrapper, and direct daemon
  wrapper path are gone.
- The CLI/DDNS Route 53 update and timer path are gone.
- The interpreter and summary layer now use one canonical structured DAG outcome model.
- Pulumi subprocess handling now injects `PRODBOX_ALLOW_NON_ENTRYPOINT=1`.
- `Settings()` reads `.env` only from the fixed repository root.
- The certificate issuance path is canonicalized to `letsencrypt-http01`.
- Hook-oriented `pre-commit` dependency and config residue are gone.
- The repository-side legacy cleanup ledger is now empty.
- Local reruns of `poetry run prodbox check-code` and `poetry run prodbox test unit` passed on
  April 6, 2026.
- `poetry run prodbox test integration charts-platform`,
  `poetry run prodbox test integration gateway-daemon`, and
  `poetry run prodbox test integration gateway-pods` all passed on April 6, 2026.
- The remaining work for this sprint is now limited to blocked AWS-backed proof reruns.

### Remaining Work

- Rerun `poetry run prodbox test integration dns-aws` in an AWS environment with
  `route53:CreateHostedZone`.
- Rerun `poetry run prodbox pulumi up --yes` and `poetry run prodbox test integration pulumi` in
  an AWS environment with `route53:GetHostedZone`.
- Rerun `poetry run prodbox test integration public-dns` in an AWS environment with
  `route53:GetHostedZone` access to `ROUTE53_ZONE_ID`.
- Close the sprint only after the blocked AWS-backed proof paths pass from the canonical CLI
  surface.

## Sprint 4.3: Adaptive Edge Infrastructure Reconcile and Ingress Ownership 🔄

**Status**: Active
**Implementation**: `src/prodbox/settings.py`, `src/prodbox/infra/__main__.py`, `src/prodbox/infra/metallb.py`, `src/prodbox/infra/ingress.py`, `src/prodbox/infra/cert_manager.py`, `src/prodbox/infra/cluster_issuer.py`, `charts/vscode/templates/ingress.yaml`, `src/prodbox/cli/host.py`, `src/prodbox/cli/dag_builders.py`, `src/prodbox/cli/interpreter.py`, `tests/integration/test_charts_platform.py`
**Docs to update**: `documents/engineering/README.md`, `documents/engineering/cli_command_surface.md`, `documents/engineering/dependency_management.md`, `documents/engineering/helm_chart_platform_doctrine.md`, `documents/engineering/local_registry_pipeline.md`, `documents/engineering/prerequisite_doctrine.md`, `documents/engineering/unit_testing_policy.md`

### Objective

Remove the remaining operator-supplied local-network and ingress-controller assumptions from the
supported edge stack so MetalLB, Traefik, cert-manager, and public-host diagnostics are owned by
canonical automation rather than ad hoc operator knowledge.

### Deliverables

- MetalLB address allocation is robust to whichever LAN subnet the home router assigns to the host,
  with deterministic auto-selection replacing router-specific `.env` defaults on the supported path.
- The canonical cluster-infrastructure reconcile path owns MetalLB, Traefik, cert-manager, and
  `letsencrypt-http01` bootstrap or adoption end-to-end.
- The supported path resolves public `80/443` through one cluster-edge controller only, with
  Traefik owning the supported `IngressClass` and bundled ingress-nginx excluded from the public
  edge.
- `vscode-nginx` remains a namespace-local auth proxy behind Traefik rather than a competing
  cluster-edge ingress surface.
- Local recovery of MetalLB, Traefik, and cert-manager is no longer blocked by Route 53 access
  that belongs only to the AWS-backed proof path.
- A named diagnostic path classifies public-host failures across host networking, ingress-class
  ownership, certificate issuance, and public-vs-private reachability before Phase 5 reruns.
- The development plan explicitly owns the remaining work needed to get the canonical public-host
  path to a self-reconciling state.

### Validation

1. `poetry run prodbox check-code`
2. `poetry run prodbox test unit`
3. `poetry run prodbox test integration cli`
4. `poetry run prodbox test integration charts-platform`
5. `poetry run prodbox test integration charts-vscode`

### Current Validation State

- `Settings()` now derives `METALLB_POOL` and `INGRESS_LB_IP` from the active LAN subnet when
  those values are blank, while preserving explicit overrides as an escape hatch.
- The canonical Pulumi path now deploys cert-manager directly and wires the
  `letsencrypt-http01` ClusterIssuer after both cert-manager and Traefik are present.
- `prodbox rke2 ensure` now forces `ingress-controller: none` into the canonical RKE2 config so
  bundled ingress-nginx does not remain part of the supported public-edge path.
- Local edge reconcile can now run with `PULUMI_ENABLE_DNS_BOOTSTRAP=false`, so MetalLB, Traefik,
  cert-manager, and the cluster issuer can recover even when the AWS-backed proof path is blocked.
- `prodbox host public-edge` now exists as the named diagnostic path for Route 53 A-record state,
  ingress-class ownership, Traefik LoadBalancer state, `vscode` ingress wiring, and certificate
  readiness.
- `poetry run prodbox test integration charts-platform` passed on April 6, 2026 after the live
  suite cleanup was hardened to remove stale retained `.data/vscode` state before each rerun.
- `poetry run prodbox host public-edge` currently fails because the active AWS identity lacks
  `route53:GetHostedZone`, `kubectl get svc traefik -n traefik-system` reports the namespace is
  absent, and the cluster still lacks the cert-manager `certificate` CRD.
- `PULUMI_ENABLE_DNS_BOOTSTRAP=false poetry run prodbox pulumi preview` is blocked until
  `PULUMI_CONFIG_PASSPHRASE` or `PULUMI_CONFIG_PASSPHRASE_FILE` is set in the current shell.
- `poetry run prodbox test integration charts-vscode` still fails because every HTTPS/TLS/auth
  probe to `https://vscode.resolvefintech.com` times out.
- `poetry run prodbox test unit` and `poetry run prodbox check-code` passed after these repo-local
  changes on April 6, 2026.

### Remaining Work

- Define `PULUMI_CONFIG_PASSPHRASE` or `PULUMI_CONFIG_PASSPHRASE_FILE`, then rerun
  `PULUMI_ENABLE_DNS_BOOTSTRAP=false poetry run prodbox pulumi up --yes` so the live cluster can
  reconcile Traefik, cert-manager, and `letsencrypt-http01` without Route 53 bootstrap access.
- Prove on the live cluster that the reconciled edge actually comes up as one coherent
  `MetalLB -> Traefik -> cert-manager -> vscode` path with bundled ingress-nginx excluded from the
  supported public edge.
- Rerun `poetry run prodbox test integration charts-vscode` once the real cluster/edge is in the
  intended state.
- Use `prodbox host public-edge` as the named preflight and close the sprint only after it reports
  a coherent Traefik-owned path for the supported public host on the live environment.

## Sprint 4.4: Always-On Gateway Supervision and DNS Continuity 🔄

**Status**: Active
**Implementation**: `src/prodbox/gateway_daemon.py`, `src/prodbox/cli/gateway.py`, `src/prodbox/cli/dag_builders.py`, `src/prodbox/cli/interpreter.py`, `src/prodbox/settings.py`, `tests/unit/test_gateway_daemon.py`, `tests/integration/test_gateway_daemon_k8s.py`, `tests/integration/test_gateway_k8s_pods.py`
**Docs to update**: `documents/engineering/README.md`, `documents/engineering/cli_command_surface.md`, `documents/engineering/distributed_gateway_architecture.md`, `documents/engineering/helm_chart_platform_doctrine.md`, `documents/engineering/unit_testing_policy.md`

### Objective

Make the gateway daemon a required continuously supervised part of the supported public-host stack
so Route 53 records stay current after WAN IP rotation and no wildcard DNS shortcut is needed.

### Deliverables

- The supported operator path keeps `prodbox gateway start <config>` running continuously under
  host-service or pod supervision and restarts it after reboot or process failure.
- The supported config-generation path includes `dns_write_gate` for explicit named public
  subdomains instead of leaving DNS writes as an optional manual add-on.
- Gateway DNS ownership updates explicit per-subdomain Route 53 records only; wildcard public DNS
  is not part of the supported architecture.
- Gateway liveness, last-public-IP observation, and DNS write health become inspectable by a named
  supported path before Phase 5 reruns.
- Manual router DynDNS or one-shot gateway invocation are no longer required to keep the canonical
  public hostname current.

### Validation

1. `poetry run prodbox check-code`
2. `poetry run prodbox test unit`
3. `poetry run prodbox test integration gateway-daemon`
4. `poetry run prodbox test integration gateway-pods`

### Current Validation State

- `prodbox gateway config-gen` now emits a canonical `dns_write_gate` section for the supported
  explicit public hostname.
- `prodbox gateway install-service` now writes, enables, and restarts the canonical systemd unit
  for continuously supervised host-side gateway runtime.
- `prodbox gateway status` and `/v1/state` now expose active-claim state, the last observed public
  IP, the last successful Route 53 write IP/timestamp, and the configured `dns_write_gate`.
- The gateway daemon still owns explicit per-subdomain Route 53 records only; wildcard public DNS
  is not part of the supported architecture.
- `poetry run prodbox test integration gateway-daemon` and
  `poetry run prodbox test integration gateway-pods` both passed on April 6, 2026 after gateway
  shutdown began tracking and awaiting per-connection reader tasks cleanly.
- `systemctl` currently reports `prodbox-gateway.service` as not found on the supported host, so
  the live host-supervision path still has not been installed.
- `poetry run prodbox test unit` and `poetry run prodbox check-code` passed after these repo-local
  changes on April 6, 2026.

### Remaining Work

- Generate or stage the live gateway config/orders file, then run
  `prodbox gateway install-service <config.json>` on the supported host so the canonical systemd
  unit exists and survives reboot or process restart without manual re-entry.
- Prove that the live Route 53 record for the supported public host tracks the active WAN IP after
  gateway supervision is in place.
- Close the sprint only after the supported public-host path no longer depends on manual daemon
  starts, wildcard DNS, or external DynDNS to keep explicit Route 53 records current.

## Sprint 4.5: Storage Path Migration, Single StorageClass, and HA Doctrine ✅

**Status**: Done
**Implementation**: `src/prodbox/lib/chart_platform.py`, `src/prodbox/lib/prodbox_k8s.py`, `src/prodbox/settings.py`, `charts/keycloak-postgres/templates/statefulset.yaml`, `charts/keycloak-postgres/values.yaml`, `charts/keycloak/templates/deployment.yaml`, `charts/keycloak/values.yaml`, `charts/vscode/templates/deployment.yaml`, `charts/vscode/values.yaml`, `tests/unit/test_chart_platform.py`, `tests/unit/test_prodbox_k8s.py`, `tests/unit/test_effects.py`, `tests/unit/test_interpreter.py`, `tests/integration/test_charts_storage.py`, `tests/integration/test_charts_platform.py`
**Docs to update**: `documents/engineering/storage_lifecycle_doctrine.md`, `documents/engineering/helm_chart_platform_doctrine.md`

### Objective

Consolidate retained storage to one StorageClass, migrate the `.data/` host-path scheme from
4 segments to 5 segments, enforce Helm-only service deployment, and adopt HA-mode defaults.

### Architecture

**Storage path scheme** (supersedes the Sprint 3.1 4-segment layout):

```
.data/<namespace>/<release>/<workload>/<ordinal>/<claim>
```

- `namespace` — Kubernetes namespace (e.g. `default`)
- `release` — Helm release name or cluster identifier
- `workload` — StatefulSet name (e.g. `postgres`, `minio`)
- `ordinal` — Pod ordinal index (`0`, `1`, …)
- `claim` — PVC claim suffix (typically `data`)

**Single StorageClass**: The cluster uses exactly one StorageClass named `manual` with provisioner
`kubernetes.io/no-provisioner`. The two previous names (`prodbox-local-retain` and
`prodbox-chart-null-storage`) have been consolidated into `manual`. Bootstrap fails if a chart
requests a dynamic provisioner.

**PV pre-creation**: PVs are created explicitly before Helm install. No implicit PVC provisioning
is permitted. PVCs are created only by Helm charts deploying StatefulSets.

**Helm-only service deployment**: All cluster services are deployed via Helm. Pulumi orchestrates
infrastructure Helm releases (MetalLB, Traefik, cert-manager). The `prodbox charts` platform
manages application Helm releases.

**HA-mode defaults**: All stateful services deploy with multiple replicas and pod anti-affinity.
Dev mode (`PRODBOX_DEV_MODE=true`, the default) suppresses anti-affinity constraints but retains
multi-replica defaults.

**Path stability**: The naming scheme is stable across teardown/rebuild cycles so data
survives cluster down and cluster up. No tooling or CLI command is permitted to delete `.data/`
itself. `.data/` appears in both `.gitignore` and `.dockerignore`.

### Deliverables

- StorageClass names in `chart_platform.py` and `prodbox_k8s.py` changed to `manual`.
- `_storage_binding()` adopted the 5-segment path scheme.
- PV naming adopted the 5-segment scheme.
- `ChartStorageSpec` gained a `claim_suffix` field; `ChartStorageBinding` gained `release_name`
  and `claim_suffix` fields.
- HA-mode Helm values (`replicaCount`, `podAntiAffinity.enabled`) added to all chart definitions.
- `PRODBOX_DEV_MODE` setting suppresses pod anti-affinity while retaining replica counts.
- Bootstrap validation rejects charts that request a non-`manual` StorageClass.
- Every Helm deploy passes the `manual` storage class explicitly via `CHART_STORAGE_CLASS_NAME`.
- `documents/engineering/storage_lifecycle_doctrine.md` and
  `documents/engineering/helm_chart_platform_doctrine.md` are updated.

### Validation

1. `poetry run prodbox check-code` — passed on April 7, 2026.
2. `poetry run prodbox test unit` — passed on April 7, 2026 (994 tests).
3. `poetry run prodbox test integration charts-storage`
4. `poetry run prodbox test integration charts-platform`
5. `poetry run prodbox test integration lifecycle`

### Remaining Work

None.

## Sprint 4.6: Configuration Simplification and K8s Secret Injection ✅

**Status**: Done
**Implementation**: `src/prodbox/settings.py`, `src/prodbox/lib/chart_platform.py`, `src/prodbox/cli/dag_builders.py`, `src/prodbox/infra/providers.py`, `src/prodbox/infra/metallb.py`, `src/prodbox/infra/ingress.py`, `src/prodbox/infra/__main__.py`, `tests/unit/test_chart_platform.py`, `tests/unit/test_settings.py`, `tests/unit/test_dag_builders.py`, `tests/unit/test_infra_program.py`, `tests/integration/test_charts_platform.py`, `tests/integration/test_charts_storage.py`
**Docs to update**: `documents/engineering/helm_chart_platform_doctrine.md`, `README.md`, `.env.example`

### Objective

Simplify `.env` to carry only external auth and non-secret configuration; auto-generate
cluster-internal secrets at deploy time via retained `.data/` storage; enforce always-dynamic
IP addressing; remove `KUBECONFIG` and `PULUMI_STACK` from the settings surface.

### Architecture

**`.env` scope** (after this sprint):

| Setting | Stays in `.env` | Why |
|---------|-----------------|-----|
| `AWS_ACCESS_KEY_ID` | Yes | External auth — real secret |
| `AWS_SECRET_ACCESS_KEY` | Yes | External auth — real secret |
| `AWS_SESSION_TOKEN` | Yes | External auth — optional |
| `AWS_REGION` | Yes | Non-secret config |
| `ROUTE53_ZONE_ID` | Yes | Non-secret config |
| `DEMO_FQDN` | Yes | Non-secret config |
| `DEMO_TTL` | Yes | Non-secret config |
| `VSCODE_FQDN` | Yes | Non-secret config |
| `ACME_EMAIL` | Yes | Non-secret config |
| `ACME_SERVER` | Yes | Non-secret config |
| `PRODBOX_DEV_MODE` | Yes | Non-secret config |
| `PULUMI_ENABLE_DNS_BOOTSTRAP` | Yes | Non-secret config |
| `BOOTSTRAP_PUBLIC_IP_OVERRIDE` | Yes | Non-secret config |
| `KEYCLOAK_ADMIN_PASSWORD` | **Removed** | Auto-generated, persisted in `.data/` |
| `KEYCLOAK_POSTGRES_PASSWORD` | **Removed** | Auto-generated, persisted in `.data/` |
| `KEYCLOAK_NGINX_CLIENT_SECRET` | **Removed** | Auto-generated, persisted in `.data/` |
| `METALLB_POOL` | **Removed** | Always auto-discovered |
| `INGRESS_LB_IP` | **Removed** | Always auto-discovered |
| `KUBECONFIG` | **Removed** | Default `~/.kube/config` always used |
| `PULUMI_STACK` | **Removed** | Hardcoded to `home` |

**Cluster-internal secret injection**: `keycloak_admin_password`,
`keycloak_postgres_password`, and `keycloak_nginx_client_secret` are auto-generated with
`secrets.token_urlsafe(24)` at first chart deploy and persisted in
`.data/<namespace>/.secrets.json`. On subsequent deploys, existing secrets are read back from
the retained `.data/` directory. This ensures stable credentials across teardown/rebuild
cycles without requiring `.env` configuration.

**IP auto-discovery**: `METALLB_POOL` and `INGRESS_LB_IP` settings are removed from
the settings surface. The auto-discovery path (`discover_lan_addressing()`) becomes the
only path; the explicit-override escape hatch is removed. Infra code (`metallb.py`,
`ingress.py`) calls `discover_lan_addressing()` directly.

### Deliverables

- Removed `KEYCLOAK_ADMIN_PASSWORD`, `KEYCLOAK_POSTGRES_PASSWORD`, and
  `KEYCLOAK_NGINX_CLIENT_SECRET` from `Settings` and `SETTING_SPECS`.
- Chart platform auto-generates these secrets via `resolve_chart_secrets()` and persists
  them in `.data/<namespace>/.secrets.json`, reading them back on subsequent deploys.
- Removed `METALLB_POOL` and `INGRESS_LB_IP` from `Settings` and `SETTING_SPECS`;
  `discover_lan_addressing()` is the sole source.
- Removed `KUBECONFIG` from `Settings` and `SETTING_SPECS`; `providers.py` hardcodes
  `~/.kube/config`.
- Removed `PULUMI_STACK` from `Settings`, `SETTING_SPECS`, and all DAG builder references;
  `_resolve_pulumi_stack()` defaults to `"home"`.
- `.env` template rendering omits removed settings.
- Engineering docs and README reflect the simplified `.env` surface.

### Validation

1. `poetry run prodbox check-code` — passed on April 7, 2026.
2. `poetry run prodbox test unit` — passed on April 7, 2026 (991 tests).
3. `poetry run prodbox env show` (must not display removed settings)
4. `poetry run prodbox test integration charts-platform`
5. `poetry run prodbox test integration charts-storage`

### Remaining Work

None.

## Documentation Requirements

**Engineering docs to create/update:**

- `documents/engineering/storage_lifecycle_doctrine.md` - 5-segment path scheme, `manual`
  StorageClass, PV pre-creation and PVC-only-from-StatefulSet doctrine.
- `documents/engineering/helm_chart_platform_doctrine.md` - 5-segment path scheme, `manual`
  StorageClass, Helm-only service deployment, HA-mode defaults.
- `documents/engineering/aws_integration_environment_doctrine.md` - blocked AWS rerun rules and
  canonical auth ownership.
- `documents/engineering/cli_command_surface.md` - canonical command and validation paths.
- `documents/engineering/dependency_management.md` - supported local tooling doctrine.
- `documents/engineering/distributed_gateway_architecture.md` - gateway startup and DNS ownership.
- `documents/engineering/helm_chart_platform_doctrine.md` - supported chart and `vscode` paths.
- `documents/engineering/integration_fixture_doctrine.md` - fixture-owned teardown and cleanup
  doctrine.
- `documents/engineering/local_registry_pipeline.md` - local registry and container build doctrine.
- `documents/engineering/prerequisite_doctrine.md` - prerequisite registry cleanup.
- `documents/engineering/storage_lifecycle_doctrine.md` - retained storage and rebinding contract.
- `documents/engineering/unit_testing_policy.md` - authoritative named validation paths.

**Product docs to create/update:**

- None.

**Cross-references to add:**

- Keep cleanup and compatibility ownership pointed at
  `DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md`.

## Related Documents

- [README.md](README.md)
- [00-overview.md](00-overview.md)
- [system-components.md](system-components.md)
- [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md)
