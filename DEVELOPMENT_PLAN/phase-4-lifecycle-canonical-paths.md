# File: DEVELOPMENT_PLAN/phase-4-lifecycle-canonical-paths.md
# Phase 4: Lifecycle Hardening and Canonical-Path Cleanup

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [00-overview.md](00-overview.md), [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md), [system-components.md](system-components.md)

> **Purpose**: Capture the lifecycle hardening work that removes cleanup-settling retries and the
> canonical-path cleanup work that leaves one supported surface per major capability.

## Phase Summary

This phase hardens `rke2 cleanup` until lifecycle validation passes without settling retries, then
removes duplicate or compatibility-only runtime, CLI, validation, and tooling paths, closes
the remaining local edge-infrastructure automation gaps around MetalLB, Traefik, cert-manager,
always-on gateway supervision, explicit per-subdomain DNS continuity, and public-host diagnostics,
consolidates the retained storage model to one StorageClass, migrates the `.data/` path scheme
to 5 segments, adopts HA-mode deployment doctrine, replaces `.env` with a Dhall configuration
file as the single config source, and enforces subprocess credential isolation so no host
credentials leak via `os.environ` inheritance. All cleanup history remains centralized in
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

## Sprint 4.2: Canonical-Path Cleanup and Legacy Removal ✅

**Status**: Done
**Implementation**: `src/prodbox/cli/gateway.py`, `src/prodbox/settings.py`, `src/prodbox/cli/summary.py`, `src/prodbox/lib/lint/`
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
- `Settings()` loads from `prodbox-config.json` compiled from Dhall.
- The certificate issuance path is canonicalized to `letsencrypt-http01`.
- Hook-oriented `pre-commit` dependency and config residue are gone.
- The repository-side legacy cleanup ledger is now empty.
- IAM policy `prodbox-integration-tests` attached to `bathurst-resolvefintech-dns` on
  April 9, 2026, granting Route 53, S3, EC2, IAM, and EKS permissions for all AWS-backed
  integration suites.
- `prodbox-config.dhall` and `prodbox-config.json` created from system credentials on
  April 9, 2026 (Route 53 zone `Z07495372G135SKEMQJZU`, ACME email `matt@resolvefintech.com`).
- `poetry run prodbox test integration dns-aws` passed on April 9, 2026 (2 tests).
- `poetry run prodbox test integration pulumi` passed on April 9, 2026 (1 test).
- `poetry run prodbox test integration public-dns` passed on April 9, 2026 (2 tests).
- `poetry run prodbox test integration aws-foundation` passed on April 9, 2026 (1 test).
- `poetry run prodbox test integration aws-eks` passed on April 9, 2026 (1 test).
- Stale integration tests `test_cli_env.py` and `test_cli_commands.py` updated to use
  `prodbox config` instead of removed `prodbox env` command group.
- `poetry run prodbox check-code` and `poetry run prodbox test unit` passed on April 9, 2026
  (953 unit tests, 17 non-integration CLI tests).

### Remaining Work

None.

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
- Pulumi local backend initialized with `PULUMI_CONFIG_PASSPHRASE=""` on April 9, 2026.
  `pulumi up --yes` deployed all 14 infrastructure resources: MetalLB (IP pool
  `192.168.2.240-192.168.2.250`), Traefik (LoadBalancer at `192.168.2.240`), cert-manager,
  `letsencrypt-http01` ClusterIssuer, and Route 53 `demo.resolvefintech.com` A record.
- Stale webhooks from prior installations cleaned up: `cert-manager-a92f4999-webhook`
  (ValidatingWebhookConfiguration and MutatingWebhookConfiguration), `metallb-webhook-configuration`
  (ValidatingWebhookConfiguration), and `traefik` IngressClass.
- `prodbox charts deploy vscode` succeeded on April 9, 2026 — full `keycloak-postgres`,
  `keycloak`, and `vscode` stack running with ingress at `vscode.resolvefintech.com`.
- Local ingress verified: `curl -sk https://192.168.2.240 -H 'Host: vscode.resolvefintech.com'`
  returns HTTP 302 redirect to Keycloak login.
- `poetry run prodbox test integration charts-platform` passed on April 9, 2026 (8 tests).
- `poetry run prodbox test integration charts-storage` passed on April 9, 2026 (12 tests).
- Router port forwarding currently routes ports 80/443 to `192.168.2.79` (host) instead of
  `192.168.2.240` (MetalLB ingress IP). Public HTTPS probes to `vscode.resolvefintech.com`
  return connection refused.
- `poetry run prodbox test integration charts-vscode` fails all 8 tests with connection refused
  to `https://vscode.resolvefintech.com` due to missing port forwarding to MetalLB.
- Let's Encrypt HTTP-01 certificate issuance pending: requires public port 80 reachable at the
  MetalLB ingress IP for ACME validation.

### Remaining Work

- Update router port forwarding: redirect ports 80 and 443 from `192.168.2.79` to
  `192.168.2.240` (MetalLB Traefik ingress IP) via the Sagemcom gateway API at `192.168.2.1`.
- Wait for Let's Encrypt HTTP-01 certificate issuance (`kubectl get certificate vscode-tls -n
  vscode` must show Ready).
- Rerun `poetry run prodbox test integration charts-vscode` once the public HTTPS path is live.
- Use `prodbox host public-edge` as the named preflight and close the sprint only after it reports
  a coherent Traefik-owned path for the supported public host on the live environment.

## Sprint 4.4: Always-On Gateway Supervision and DNS Continuity ⏸️

**Status**: Blocked
**Blocked by**: Gateway service not yet installed on host
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
- `poetry run prodbox test integration gateway-daemon` passed on April 9, 2026 (1 test).
- `poetry run prodbox test integration gateway-pods` passed on April 9, 2026 (15 tests).
- Live cluster re-established with RKE2, cert-manager, MetalLB, and Traefik on April 9, 2026.
- `systemctl` currently reports `prodbox-gateway.service` as not found on the supported host, so
  the live host-supervision path still has not been installed.
- `poetry run prodbox test unit` and `poetry run prodbox check-code` passed on April 9, 2026.

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
3. `poetry run prodbox config show` (must not display removed settings)
4. `poetry run prodbox test integration charts-platform`
5. `poetry run prodbox test integration charts-storage`

### Remaining Work

None.

## Sprint 4.7: Dhall Config Schema, Bootstrap, and JSON Loading ✅

**Status**: Done
**Implementation**: `prodbox-config-types.dhall`, `src/prodbox/settings.py`, `src/prodbox/cli/config_cmd.py`, `src/prodbox/cli/main.py`, `src/prodbox/cli/command_adt.py`, `src/prodbox/cli/dag_builders.py`, `src/prodbox/cli/effects.py`, `src/prodbox/cli/interpreter.py`
**Docs to update**: `documents/engineering/dependency_management.md`, `documents/engineering/cli_command_surface.md`

### Objective

Establish Dhall as the single configuration source with a compile-to-JSON pipeline and a
one-time bootstrap command that populates the Dhall config from the current system state.

### Architecture

**Config file layout:**

```
prodbox-config-types.dhall   -- version-controlled schema with defaults
prodbox-config.dhall         -- gitignored user config (contains secrets)
prodbox-config.json          -- gitignored compiled output (read by Python)
```

**Schema** (maps to current `Settings` fields):

```dhall
{ aws : { access_key_id : Text, secret_access_key : Text, session_token : Optional Text, region : Text }
, route53 : { zone_id : Text }
, domain : { demo_fqdn : Text, demo_ttl : Natural, vscode_fqdn : Optional Text }
, acme : { email : Text, server : Text }
, deployment : { dev_mode : Bool, bootstrap_public_ip_override : Optional Text, pulumi_enable_dns_bootstrap : Bool }
}
```

**Not in Dhall** (always auto-discovered at runtime via `discover_lan_addressing()`):
`active_lan_interface`, `active_lan_ipv4`, `active_lan_network_cidr`, `metallb_pool`,
`ingress_lb_ip`.

**Bootstrap flow** (`prodbox config init`):

1. Check `dhall-to-json` exists (fail fast).
2. If `.env` exists: parse it, map keys to Dhall field paths.
3. Call `discover_lan_addressing()` for informational display (not stored).
4. Write `prodbox-config.dhall` importing `./prodbox-config-types.dhall`.
5. Run `dhall-to-json < prodbox-config.dhall > prodbox-config.json`.
6. Validate by loading `Settings.from_config_json()`.
7. This is the last time `.env` or host system values are used.

### Deliverables

- `prodbox-config-types.dhall` checked into the repository (schema with defaults).
- `prodbox-config.dhall` and `prodbox-config.json` added to `.gitignore` and `.dockerignore`.
- `prodbox config compile` command shells out to `dhall-to-json`.
- `prodbox config init` command performs one-time bootstrap from `.env` and system state.
- `prodbox config show` and `prodbox config validate` commands.
- `dhall` and `dhall-to-json` added to `ValidateEnvironment` tool check list in prerequisite
  registry.
- New `load_config_json(path: Path) -> dict[str, object]` function in `settings.py`.
- New `Settings.from_config_json()` class method that maps nested JSON to flat Settings fields.

### Validation

1. `poetry run prodbox check-code`
2. `poetry run prodbox test unit`
3. `poetry run prodbox config init` (generates valid Dhall from `.env`)
4. `poetry run prodbox config compile` (compiles Dhall to JSON)
5. `poetry run prodbox config validate` (validates compiled JSON)

### Remaining Work

None.

### Validation State

- `poetry run prodbox check-code` and `poetry run prodbox test unit` passed on April 8, 2026
  (953 unit tests).

## Sprint 4.8: Settings Migration and AWS Auth Removal ✅

**Status**: Done
**Implementation**: `src/prodbox/settings.py`, `src/prodbox/lib/aws_auth.py` (deletion), `src/prodbox/cli/interpreter.py`, `src/prodbox/gateway_daemon.py`, `tests/conftest.py`, `tests/unit/test_settings.py`, `tests/unit/test_aws_auth.py` (deletion)
**Docs to update**: `documents/engineering/aws_integration_environment_doctrine.md`, `documents/engineering/helm_chart_platform_doctrine.md`

### Objective

Replace Pydantic `BaseSettings` (`.env`-driven) with a plain `BaseModel` that loads from
Dhall-compiled JSON. Remove the standalone AWS auth module; all credential access flows through
`Settings`.

### Deliverables

- `Settings` inherits from `BaseModel` instead of `BaseSettings`.
- `pydantic-settings` removed from `pyproject.toml`.
- `settings_customise_sources()`, `require_dotenv_aws_auth` validator, and
  `_resolve_repo_dotenv_path()` removed.
- `derive_local_edge_defaults` model validator retained (LAN auto-discovery unchanged).
- `get_settings()` loads from `prodbox-config.json` via `Settings.from_config_json()`.
- `src/prodbox/lib/aws_auth.py` deleted entirely.
- `_load_repo_aws_auth()` removed from interpreter; boto3 session call sites read credentials
  from `get_settings()` directly.
- Gateway daemon AWS credential loading updated.
- Test `mock_env` fixture rewritten to produce `prodbox-config.json` instead of `.env`.
- `SETTING_SPECS` updated: env_var names become config field paths.

### Validation

1. `poetry run prodbox check-code`
2. `poetry run prodbox test unit`
3. No `.env` file is read by any prodbox code path.

### Remaining Work

None.

### Validation State

- `poetry run prodbox check-code` and `poetry run prodbox test unit` passed on April 8, 2026
  (953 unit tests).

## Sprint 4.9: Subprocess Credential Isolation and Legacy Cleanup ✅

**Status**: Done
**Implementation**: `src/prodbox/cli/interpreter.py`, `src/prodbox/cli/env.py` (removal), `tests/integration/aws_helpers.py`
**Docs to update**: `CLAUDE.md`, `README.md` (root), `documents/engineering/cli_command_surface.md`, `documents/engineering/aws_integration_environment_doctrine.md`

### Objective

Build subprocess environments from explicit configuration only, eliminating `os.environ`
inheritance as a credential leak vector. Remove the deprecated `prodbox env` command group.

### Deliverables

- New `_base_subprocess_env()` static method on `EffectInterpreter`: constructs a minimal
  environment with only `PATH`, `HOME`, `LANG`, `TERM`, `USER`.
- `_kubectl_env()` refactored to use `_base_subprocess_env()` plus `KUBECONFIG`.
- `_pulumi_env()` refactored to use `_base_subprocess_env()` plus AWS credentials from
  `Settings` plus extra_env.
- `build_dotenv_aws_env()` call sites in integration test helpers replaced.
- `prodbox env` command group removed entirely.
- All remaining `.env` parsing code removed from the repository.
- `CLAUDE.md` and root `README.md` updated to describe Dhall config workflow.
- `.env` removal items added to `legacy-tracking-for-deletion.md` completed section.

### Validation

1. `poetry run prodbox check-code`
2. `poetry run prodbox test unit`
3. `poetry run prodbox test integration cli`
4. Subprocess env inspection confirms no leaked host credentials.

### Remaining Work

None.

### Validation State

- `poetry run prodbox check-code` and `poetry run prodbox test unit` passed on April 8, 2026
  (953 unit tests).

## Sprint 4.10: AWS Fixture Leak Prevention ✅

**Status**: Done
**Implementation**: `tests/integration/conftest.py`, `src/prodbox/cli/aws_cmd.py`, `src/prodbox/cli/main.py`, `tests/integration/sweep_runner.py`
**Docs to update**: `documents/engineering/cli_command_surface.md`, `documents/engineering/aws_integration_environment_doctrine.md`

### Objective

Prevent leaked ephemeral AWS resources from accumulating when integration test processes crash
before fixture teardown runs. EKS clusters cost $0.10/hr; a leaked cluster costs $2.40/day until
cleanup.

### Architecture

**Three layers of defense:**

1. **Pre-test sweep** (session fixture): A session-scoped autouse fixture in
   `tests/integration/conftest.py` runs `sweep_expired_fixture_resources()` at the start of every
   integration test session. Any leaked resources from prior crashes are cleaned up before new
   tests create fresh resources.

2. **CLI janitor command**: `prodbox aws sweep-fixtures` provides an out-of-band entrypoint to run
   the janitor sweep without running the test suite. Follows the thin Click wrapper pattern from
   `tla.py`.

3. **Cron supervision**: A cron entry on the supported host runs the CLI janitor every hour so
   expired resources are cleaned up even if the test suite is not run again.

### Deliverables

- Session-scoped `sweep_expired_aws_fixtures` fixture in `tests/integration/conftest.py` with
  best-effort try/except so a sweep failure does not block the test session.
- `prodbox aws sweep-fixtures` CLI command as a thin Click wrapper around the existing
  `sweep_expired_fixture_resources()` function in `tests/integration/aws_helpers.py`.
- `aws` command group registered in `src/prodbox/cli/main.py`.
- Cron entry: `0 * * * * cd /home/matthewnowak/prodbox && poetry run prodbox aws sweep-fixtures`.

### Validation

1. `poetry run prodbox aws sweep-fixtures` runs without error.
2. `poetry run prodbox check-code`
3. `poetry run prodbox test unit`
4. Verify cron entry exists: `crontab -l | grep sweep-fixtures`.

### Validation State

- `poetry run prodbox check-code` passed on April 9, 2026.
- `poetry run prodbox test unit` passed on April 9, 2026 (953 tests).
- `crontab -l | grep sweep-fixtures` confirms hourly cron entry: `0 * * * * cd /home/matthewnowak/prodbox && poetry run prodbox aws sweep-fixtures >> /tmp/prodbox-sweep.log 2>&1`.
- `prodbox aws sweep-fixtures` CLI command registered and functional.

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
