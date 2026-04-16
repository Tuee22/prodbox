# File: DEVELOPMENT_PLAN/phase-4-lifecycle-canonical-paths.md
# Phase 4: Lifecycle Hardening and Canonical-Path Cleanup

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [00-overview.md](00-overview.md), [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md), [system-components.md](system-components.md)

> **Purpose**: Capture the lifecycle hardening work that removes cleanup-settling retries and the
> canonical-path cleanup work that leaves one supported surface per major capability.

## Phase Summary

This phase hardens the lifecycle surface, removes duplicate or compatibility-only runtime, CLI,
validation, and tooling paths, closes the remaining local edge-infrastructure automation gaps
around MetalLB, Traefik, cert-manager, always-on gateway supervision, explicit per-subdomain DNS
continuity, and public-host diagnostics, converges retained storage on one config-declared PV root
and one `manual` StorageClass, and now also moves AWS test provisioning and teardown entirely under
Pulumi. Under the reopened doctrine, this phase reserves the manual PV root purely for PV content,
extends Dhall config to declare that root explicitly, replaces remnant-preserving cluster cleanup
with full cluster delete/install semantics, requires cluster install to recreate `manual` while
deleting every other StorageClass, and adds automatic Pulumi test-stack destroy before local cluster
delete removes the MinIO backend host. All cleanup history remains centralized in
[legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md).

## Sprint 4.1: Legacy Cleanup Hardening and Lifecycle Regression Closure ✅

**Status**: Done
**Implementation**: `src/prodbox/cli/rke2.py`, `src/prodbox/cli/interpreter.py`, `tests/integration/test_prodbox_lifecycle.py`
**Docs to update**: `documents/engineering/README.md`, `documents/engineering/integration_fixture_doctrine.md`, `documents/engineering/prerequisite_doctrine.md`, `documents/engineering/storage_lifecycle_doctrine.md`

### Objective

Make the legacy cleanup surface stable enough that the lifecycle suite does not need retry-based settling.

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

- Repository-wide status tracking is centralized in this plan suite, and
  `legacy-tracking-for-deletion.md` is the only cleanup ledger for removed or compatibility-only
  surfaces.
- The compatibility-only prerequisite, daemon-wrapper, timer-based Route 53 path, hook-oriented
  tooling residue, and duplicate CLI paths owned by this sprint are no longer present on the
  supported architecture.
- Structured DAG outcomes, Dhall-backed settings auto-compilation, and the canonical
  `letsencrypt-http01` issuance path are now the only supported implementations for the affected
  surfaces.
- `poetry run prodbox check-code` passed on April 15, 2026 after the latest clean-room rerun.
- `poetry run prodbox test unit` passed on April 15, 2026 (`1075 passed`).
- The April 15, 2026 destructive aggregate rerun through `poetry run prodbox test all`
  re-proved the CLI, gateway, chart, Route 53, EKS, Pulumi, lifecycle, and IAM surfaces that
  depend on this cleanup work.

### Remaining Work

None.

## Sprint 4.3: Adaptive Edge Infrastructure Reconcile and Ingress Ownership ✅

**Status**: Done
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
- The canonical RKE2 config now forces `ingress-controller: none` so bundled ingress-nginx does
  not remain part of the supported public-edge path.
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
- Router port forwarding updated on April 10, 2026: ports 80/443 now route to `192.168.2.240`
  (MetalLB Traefik ingress IP) via the Sagemcom gateway API at `192.168.2.1`.
- Let's Encrypt certificate issued via DNS-01 challenge on April 10, 2026; `kubectl get
  certificate vscode-tls -n vscode` shows Ready.
- `/etc/hosts` entry added for `vscode.resolvefintech.com` → `192.168.2.240` to work around
  NAT hairpinning limitation on the Sagemcom router.
- `poetry run prodbox test integration charts-vscode` passed on April 10, 2026 (8 tests).
- `prodbox host public-edge` reports `CLASSIFICATION=ready-for-external-proof` with Route 53
  in-sync, Traefik at `192.168.2.240`, certificate ready, and correct IngressClass.
- Stale webhooks from prior installations cleaned up on April 10, 2026.
- `prodbox host public-edge` Traefik service lookup updated to use label selector
  `app.kubernetes.io/name=traefik` instead of hardcoded service name, accommodating
  Pulumi-generated Helm release names.

### Remaining Work

None.

## Sprint 4.4: In-Cluster Gateway Daemon and DNS Continuity ✅

**Status**: Done
**Implementation**: `charts/gateway/` (new), `src/prodbox/gateway_daemon.py`, `src/prodbox/cli/gateway.py`, `src/prodbox/lib/chart_platform.py`, `src/prodbox/cli/test_cmd.py`, `tests/unit/test_gateway_daemon.py`, `tests/integration/test_gateway_k8s_pods.py`, `tests/integration/test_gateway_partition.py` (new)
**Docs to update**: `documents/engineering/README.md`, `documents/engineering/cli_command_surface.md`, `documents/engineering/distributed_gateway_architecture.md`, `documents/engineering/helm_chart_platform_doctrine.md`, `documents/engineering/unit_testing_policy.md`

### Objective

Make the gateway daemon a long-running in-cluster Kubernetes workload that owns Route 53 write
continuity, leader election, and failover, and explicitly handles all failure modes the public-host
stack depends on. No prodbox daemon runs on the host.

### Deliverables

- A `prodbox charts deploy gateway` path installs the gateway as a Kubernetes workload
  (Deployment or StatefulSet) under the canonical chart-platform doctrine.
- The gateway pod runs `prodbox gateway start` against an in-cluster mounted config.
- Leader election guarantees exactly one writer to Route 53 at any time across replicas.
- The gateway tolerates pod loss (Kubernetes restart), node loss (rescheduling), and network
  partitions (partition heals re-converge to a single leader without split-brain Route 53 writes).
- A named integration suite (`gateway-partition`) proves: pod kill, node drain, controlled
  split-brain, leader handoff, and Route 53 write quiescence under contention.
- The supported config-generation path includes `dns_write_gate` for explicit named public
  subdomains; wildcard public DNS is not part of the supported architecture.
- Gateway liveness, last-public-IP observation, and DNS write health are inspectable by
  `prodbox gateway status` against the in-cluster pod before Phase 5 reruns.
- The supported config and docs treat `prodbox gateway install-service` and
  `prodbox-gateway.service` as removed surfaces (deferred to Sprint 4.12).

### Validation

1. `poetry run prodbox check-code`
2. `poetry run prodbox test unit`
3. `poetry run prodbox test integration gateway-pods`
4. `poetry run prodbox test integration gateway-partition` (new suite)
5. Live: deploy the gateway chart, kill the elected leader pod, and observe Route 53 record
   continuity during the next WAN IP change.

### Current Validation State

- `prodbox gateway config-gen` emits a canonical `dns_write_gate` section for the supported
  explicit public hostname.
- `prodbox gateway status` and `/v1/state` expose active-claim state, the last observed public
  IP, the last successful Route 53 write IP/timestamp, and the configured `dns_write_gate`.
- `poetry run prodbox test integration gateway-daemon` passed on April 9, 2026 (1 test).
- `poetry run prodbox test integration gateway-pods` passed on April 9, 2026 (15 tests).
- Live cluster re-established with RKE2, cert-manager, MetalLB, and Traefik on April 10, 2026.
- `charts/gateway/` (Helm chart) authored on April 10, 2026 with one Deployment + Service per
  ranked node id, a per-node TLS Certificate issued by an in-namespace cert-manager Issuer,
  an orders ConfigMap covering all replicas, a per-node config ConfigMap, and a Secret
  carrying the prodbox-config.json so the daemon's Route 53 client reads AWS credentials
  through the canonical `Settings.from_config_json()` path.
- `prodbox.lib.chart_platform.CHART_REGISTRY` registers the `gateway` chart with
  `requires_public_host=True`. `build_chart_deployment_plan()` accepts a
  `gateway_event_keys` keyword and dispatches `_values_for_gateway()` which validates
  AWS credentials and zone id from settings before rendering values JSON.
- `prodbox.lib.chart_platform.resolve_gateway_event_keys()` auto-generates per-node
  HMAC signing keys and persists them in `.prodbox-state/gateway/.gateway-event-keys.json` so
  redeployments preserve mesh identity.
- `prodbox.cli.dag_builders._build_chart_deploy_effect` resolves both
  `resolve_chart_secrets()` and `resolve_gateway_event_keys()` so `prodbox charts deploy
  gateway` works through the canonical effect pipeline.
- `tests/integration/test_gateway_partition.py` exists and is wired through
  `prodbox test integration gateway-partition`. It deploys the chart via
  `deploy_chart_plan`, asserts canonical convergence on the highest-ranked node,
  exercises a pod-kill failover on the leader, and runs a NetworkPolicy
  partition/heal cycle that verifies `has_active_claim` is held only by the elected
  leader and reconverges to the canonical leader on heal.
- Existing leader-election semantics live in `_recompute_gateway_owner()` (heartbeat
  ranked-priority) plus `_emit_ownership_transition_events()` and `has_active_claim_from()`
  (claim/yield gossip). The TLA+ model in `documents/engineering/tla/gateway_orders_rule.tla`
  proves these invariants formally; `tests/integration/test_gateway_k8s_pods.py` exercises
  them against live K8s pods through pod kill, asymmetric partition, cascading failure,
  full-cluster outage, flap, and long-partition anti-entropy scenarios.
- `poetry run prodbox check-code` and `poetry run prodbox test unit` passed on
  April 10, 2026 (947 unit tests).

### Closure Validation (2026-04-10)

- `_ensure_gateway_image()` in `src/prodbox/cli/interpreter.py:2669` now publishes
  both `<repo>:<prodbox-id>` and `<repo>:latest` so the canonical cluster bootstrap path has no
  manual `docker build`/`docker push` step.
  The gateway chart's `pullPolicy: Always` (in `charts/gateway/values.yaml` and
  `_values_for_gateway()` at `src/prodbox/lib/chart_platform.py:415`) guarantees
  pods always pull the freshly published `:latest` image after a rebuild.
- The then-current cluster bootstrap path plus `poetry run prodbox pulumi up --yes` +
  `poetry run prodbox charts deploy gateway` ran cleanly against the live RKE2
  cluster on `bathurst`. The gateway chart deployed all three per-node
  Deployments to the `gateway` namespace, the cert-manager-issued mesh TLS
  material was minted, and the mesh converged on `node-a` as the canonical
  Route 53 writer.
- `/v1/state` on each pod confirmed `gateway_owner: "node-a"`,
  `has_active_claim: true` only on `node-a`,
  `last_dns_write_ip: 142.115.123.42` matching the host's real public IP, and
  fresh `last_dns_write_at_utc` timestamps every TTL.
- `poetry run prodbox test integration gateway-partition` passed all four tests
  (chart-deploy convergence, leader-only active claim, leader-deployment
  scale-to-0 failover, and NetworkPolicy partition + heal reconvergence). The
  failover test was migrated from `delete_pod_force` to
  `kubectl scale deployment --replicas=0/1` because the chart's per-node
  Deployment with `replicas: 1` recreates a pod faster than the heartbeat
  timeout, narrowing the failover window below detectability.
- Live Route 53 continuity proof: deliberately UPSERTed
  `vscode.resolvefintech.com` to `203.0.113.8`; the in-cluster leader corrected
  it back to `142.115.123.42` within one TTL (~60s), with the leader pod's
  `last_dns_write_at_utc` advancing to a timestamp newer than the corruption
  moment. Captured in `/tmp/route53-after.json`.

### Remaining Work

None.

## Sprint 4.5: Storage Path Migration, Single StorageClass, and HA Doctrine ✅

**Status**: Done
**Implementation**: `src/prodbox/lib/chart_platform.py`, `src/prodbox/lib/prodbox_k8s.py`, `src/prodbox/settings.py`, `charts/keycloak-postgres/templates/statefulset.yaml`, `charts/keycloak-postgres/values.yaml`, `charts/keycloak/templates/deployment.yaml`, `charts/keycloak/values.yaml`, `charts/vscode/templates/deployment.yaml`, `charts/vscode/values.yaml`, `tests/unit/test_chart_platform.py`, `tests/unit/test_prodbox_k8s.py`, `tests/unit/test_effects.py`, `tests/unit/test_interpreter.py`, `tests/integration/test_charts_storage.py`, `tests/integration/test_charts_platform.py`
**Docs to update**: `documents/engineering/storage_lifecycle_doctrine.md`, `documents/engineering/helm_chart_platform_doctrine.md`

### Objective

Consolidate retained storage to one StorageClass, migrate the `.data/` host-path scheme from
4 segments to 5 segments, enforce Helm-only service deployment, and adopt explicit chart replica counts.

### Architecture

**Storage path scheme** (relative to the configured manual PV host root; default `.data/`):

```
<manual-pv-root>/<namespace>/<release>/<workload>/<ordinal>/<claim>
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

**Replica-count doctrine**: Replica counts are chart-specific. Single-writer retained-state
services such as `keycloak-postgres` and `vscode` stay single-replica unless they gain explicit
clustered storage semantics, while clustered services can run multiple replicas with pod
anti-affinity. Dev mode (`PRODBOX_DEV_MODE=true`, the default) suppresses anti-affinity
constraints but retains the configured replica counts.

**Path stability**: The naming scheme is stable across cluster delete/install cycles so PV
contents survive ephemeral teardown and spin-up. No tooling or CLI command is permitted to delete
the configured manual PV root itself as part of cluster delete. The default `.data/` root appears in
both `.gitignore` and `.dockerignore`.

### Deliverables

- StorageClass names in `chart_platform.py` and `prodbox_k8s.py` changed to `manual`.
- `_storage_binding()` adopted the 5-segment path scheme.
- PV naming adopted the 5-segment scheme.
- `ChartStorageSpec` gained a `claim_suffix` field; `ChartStorageBinding` gained `release_name`
  and `claim_suffix` fields.
- Replica-count Helm values (`replicaCount`, `podAntiAffinity.enabled`) are explicit per chart.
- `PRODBOX_DEV_MODE` setting suppresses pod anti-affinity while retaining configured replica counts.
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


## Sprint 4.6: Configuration Simplification, Secret Boundary, and PV-Only Storage Root ✅

**Status**: Done
**Implementation**: `src/prodbox/settings.py`, `src/prodbox/lib/chart_platform.py`, `src/prodbox/cli/dag_builders.py`, `src/prodbox/gateway_daemon.py`, `tests/unit/test_settings.py`, `tests/integration/test_charts_platform.py`, `tests/integration/test_charts_storage.py`
**Docs to update**: `documents/engineering/helm_chart_platform_doctrine.md`, `documents/engineering/storage_lifecycle_doctrine.md`, `README.md`

### Objective

Keep external configuration simple while reserving the configured manual PV host root purely for PV
content and moving non-PV retained artifacts out of that root.

### Architecture

**Config surface**: External auth and non-secret deployment configuration remain in the Dhall/JSON
settings path. `METALLB_POOL`, `INGRESS_LB_IP`, `KUBECONFIG`, and `PULUMI_STACK` stay removed from
the public settings surface.

**Manual PV root boundary**: The configured manual PV host root (default `.data/`) is a PV-content
boundary only. Generated cluster secrets, gateway mesh keys, or any other non-PV retained artifacts
must move out of that root.

**IP auto-discovery**: `METALLB_POOL` and `INGRESS_LB_IP` remain auto-discovered. Infra code
continues to call `discover_lan_addressing()` directly.

### Deliverables

- Removed settings stay removed from `Settings` and the public config surface.
- The chart platform and gateway runtime stop treating the manual PV host root as a mixed-purpose
  persistence directory.
- Generated non-PV retained artifacts move out of the manual PV host root.
- Engineering docs and README describe the configured manual PV root as PV-content-only storage.

### Validation

1. `poetry run prodbox check-code`
2. `poetry run prodbox test unit`
3. `poetry run prodbox config show`
4. `poetry run prodbox test integration charts-platform`
5. `poetry run prodbox test integration charts-storage`

### Closure Validation (2026-04-13)

- `src/prodbox/lib/chart_platform.py` now persists generated chart secrets under
  `.prodbox-state/<namespace>/.secrets.json` and gateway mesh keys under
  `.prodbox-state/<namespace>/.gateway-event-keys.json`, leaving the configured manual PV host
  root for PV contents only.
- `poetry run prodbox rke2 delete --yes` passed on April 13, 2026 and explicitly reported both
  preserved roots: `/home/matthewnowak/prodbox/.data` and
  `/home/matthewnowak/prodbox/.prodbox-state`.
- The April 13, 2026 aggregate rerun passed `tests/integration/test_charts_platform.py`
  (8 tests) and `tests/integration/test_charts_storage.py` (13 tests) under the PV-only storage
  boundary.
- `poetry run prodbox test unit` and `poetry run prodbox check-code` both passed on April 13,
  2026 after the storage-boundary closure work.

### Remaining Work

None.

## Sprint 4.7: Dhall Config Schema, Bootstrap, and Manual PV Host Root ✅

**Status**: Done
**Implementation**: `prodbox-config-types.dhall`, `src/prodbox/settings.py`, `src/prodbox/cli/config_cmd.py`, `src/prodbox/cli/main.py`, `src/prodbox/cli/command_adt.py`, `src/prodbox/cli/dag_builders.py`, `src/prodbox/cli/effects.py`, `src/prodbox/cli/interpreter.py`
**Docs to update**: `documents/engineering/cli_command_surface.md`, `documents/engineering/dependency_management.md`, `documents/engineering/storage_lifecycle_doctrine.md`

### Objective

Keep Dhall as the single configuration source while extending it to declare the manual PV host root
explicitly and default it to the repository `.data/` directory.

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
, storage : { manual_pv_host_root : Text }
}
```

**Not in Dhall** (always auto-discovered at runtime via `discover_lan_addressing()`):
`active_lan_interface`, `active_lan_ipv4`, `active_lan_network_cidr`, `metallb_pool`,
`ingress_lb_ip`.

**Supported authoring flow** (`prodbox config setup` or manual Dhall editing):

1. Check `dhall-to-json` exists (fail fast).
2. Resolve the repository-root default manual PV host root as `.data/`.
3. Write or edit `prodbox-config.dhall` importing `./prodbox-config-types.dhall`, with the manual
   PV host root expressed explicitly.
4. Run `dhall-to-json < prodbox-config.dhall > prodbox-config.json`.
5. Commands that load canonical settings also auto-compile the repository-root Dhall config when
   `prodbox-config.json` is missing or older than the Dhall source/schema.
6. Validate by loading `Settings.from_config_json()`.

### Deliverables

- `prodbox-config-types.dhall` includes the explicit manual PV host-root field.
- `prodbox config setup` writes that field explicitly and defaults it to the repository `.data/`
  directory when the operator does not override it; manual Dhall authoring uses the same schema.
- `Settings.from_config_json()` exposes the configured manual PV host root to lifecycle and chart
  code.
- `prodbox config show` and `prodbox config validate` display and validate the configured PV root.

### Validation

1. `poetry run prodbox check-code`
2. `poetry run prodbox test unit`
3. `poetry run prodbox config setup`
4. `poetry run prodbox config compile`
5. `poetry run prodbox config show`
6. `poetry run prodbox config validate`

### Closure Validation (2026-04-13)

- `prodbox-config-types.dhall` and `prodbox-config.dhall` now declare
  `storage.manual_pv_host_root`, defaulting to `.data`.
- `prodbox config setup` and manual Dhall authoring both write the explicit `storage` block, and
  `Settings.from_config_json()` surfaces the configured root to lifecycle and chart code.
- `rm -f prodbox-config.json` removed the compiled artifact before the closure rerun; both
  `poetry run prodbox config show` and `poetry run prodbox config validate` then passed on
  April 13, 2026 and auto-regenerated `prodbox-config.json` from Dhall.
- `poetry run prodbox config show` reported
  `storage.manual_pv_host_root=/home/matthewnowak/prodbox/.data` during the April 13, 2026
  closure proof.
- `poetry run prodbox test unit`, `poetry run prodbox test all`, and `poetry run prodbox check-code`
  all passed with the explicit field present.

### Remaining Work

None.

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
**Implementation**: `tests/integration/conftest.py`, `src/prodbox/cli/aws_cmd.py`, `src/prodbox/cli/main.py`, `DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md`
**Docs to update**: `documents/engineering/cli_command_surface.md`, `documents/engineering/aws_integration_environment_doctrine.md`

### Objective

Keep AWS leak-prevention ownership explicit in the governed plan while ensuring the top-level
`prodbox aws` namespace no longer exposes janitor-era cleanup surfaces.

### Deliverables

- The `prodbox aws` top-level namespace is explicit and reserved for supported AWS flows.
- AWS cleanup ownership is explicit in the development plan and cleanup ledger instead of hidden in
  undocumented operator habits.
- The no-longer-supported session sweep, standalone janitor command, and host cron surfaces are
  recorded only in `legacy-tracking-for-deletion.md`; they are not treated as active
  implementation paths in this phase narrative.

### Validation

1. `poetry run prodbox aws --help`
2. `poetry run prodbox check-code`
3. `poetry run prodbox test unit`

### Current Validation State

- `src/prodbox/cli/main.py` registers `aws` as an explicit top-level Click group.
- `poetry run prodbox aws --help` lists the supported IAM and quota commands and no janitor-style
  sweep command.
- `legacy-tracking-for-deletion.md` is the authoritative record for the removed janitor-era
  surfaces owned by this milestone; the active codebase no longer includes a standalone sweep
  command or host cron-backed cleanup path.

### Remaining Work

None.

## Sprint 4.11: Final Subprocess Env Isolation and Settings-Only Config Access ✅

**Status**: Done
**Implementation**: `src/prodbox/cli/check_code.py`, `src/prodbox/cli/test_cmd.py`, `src/prodbox/cli/interpreter.py`
**Docs to update**: `DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md`, `DEVELOPMENT_PLAN/README.md`, `DEVELOPMENT_PLAN/00-overview.md`

### Objective

Close the remaining subprocess credential isolation gaps in `check_code.py` and `test_cmd.py`,
and remove the `os.environ.get("ROUTE53_ZONE_ID")` fallback in the interpreter so all config
access flows through `Settings` as the sole source.

### Deliverables

- `check_code.py` subprocess env builder replaced `dict(os.environ)` with an explicit
  `_TOOL_PASSTHROUGH_VARS` allowlist containing only `PATH`, `HOME`, `LANG`, `TERM`, `USER`.
- `test_cmd.py` subprocess env builder replaced `dict(os.environ)` with an explicit
  `_TEST_PASSTHROUGH_VARS` allowlist matching the interpreter passthrough vars so integration
  tests can forward Pulumi and test vars through the interpreter.
- Interpreter `_interpret_validate_route53_access` zone ID resolution removed the
  `os.environ.get("ROUTE53_ZONE_ID")` fallback; zone ID now resolves from the effect or
  `get_settings()` only.
- Stale `.env` reference in the Route 53 validation error hint updated to
  `prodbox-config.dhall`.

### Validation

1. `poetry run prodbox check-code` — passed on April 9, 2026.
2. `poetry run prodbox test unit` — passed on April 9, 2026 (953 tests).

### Remaining Work

None.

## Sprint 4.12: Host Gateway Service Removal ✅

**Status**: Done
**Implementation**: `src/prodbox/cli/gateway.py`, `src/prodbox/cli/command_adt.py`, `src/prodbox/cli/dag_builders.py`, `tests/unit/test_command_adt.py`, `tests/unit/test_dag_builders.py`, `tests/unit/test_cli_commands.py`, `documents/engineering/distributed_gateway_architecture.md`, `documents/engineering/cli_command_surface.md`
**Docs to update**: `documents/engineering/distributed_gateway_architecture.md`, `documents/engineering/cli_command_surface.md`

### Objective

Remove every host-supervised gateway surface from the codebase, the host, and the doctrine docs
now that the in-cluster gateway daemon is the only supported steady state.

### Deliverables

- `prodbox-gateway.service` is uninstalled from the supported host (`systemctl disable --now`,
  unit file deleted) and the host no longer runs any prodbox daemon.
- `prodbox gateway install-service` command, its DAG builder, and any associated prerequisite
  registry entries are removed from the CLI surface.
- All "host supervisor", "host-service install", "supervised host", and similar architectural
  language is purged from doctrine docs and CLI help. The development plan retains those terms
  only in completed-sprint history.
- Ledger entries for the removed surfaces move from Pending Removal to Completed.
- `prodbox gateway --help` does not list `install-service`.

### Validation

1. `poetry run prodbox check-code`
2. `poetry run prodbox test unit`
3. `systemctl status prodbox-gateway.service` returns "not loaded" on the supported host.
4. `prodbox gateway --help` does not list `install-service`.
5. `grep -r 'install-service' DEVELOPMENT_PLAN/` returns matches only inside completed-sprint
   history and the legacy ledger Completed section.

### Current Validation State

- `prodbox gateway install-service` Click command, `GatewayInstallServiceCommand` ADT,
  `gateway_install_service_command` smart constructor, `_build_gateway_install_service_dag`
  builder, and `_render_gateway_systemd_unit` helper are all removed from the source tree
  as of April 10, 2026.
- `documents/engineering/cli_command_surface.md` and
  `documents/engineering/distributed_gateway_architecture.md` no longer describe the
  install-service command and now state explicitly that the canonical steady state is
  `prodbox charts deploy gateway`.
- `tests/unit/test_command_adt.py`, `tests/unit/test_dag_builders.py`, and
  `tests/unit/test_cli_commands.py` no longer reference `GatewayInstallServiceCommand`;
  the latter now asserts that `prodbox gateway install-service` is rejected as an
  unknown subcommand.
- `poetry run prodbox check-code` and `poetry run prodbox test unit` passed on
  April 10, 2026 (947 unit tests, 6 fewer than before because the install-service
  test surface was removed).

### Closure Validation (2026-04-10)

- `sudo systemctl disable --now prodbox-gateway.service` executed on `bathurst`
  after the in-cluster gateway was observed converging on `node-a` and
  continuing to keep `vscode.resolvefintech.com` current in Route 53. The unit
  file at `/etc/systemd/system/prodbox-gateway.service` was removed and a
  `daemon-reload` issued. Before/after evidence captured in
  `/tmp/prodbox-gateway-before.log`, `/tmp/prodbox-gateway-pre-removal.log`, and
  `/tmp/prodbox-gateway-after.log`.
- Re-verification step (`systemctl status prodbox-gateway.service`) reports
  `Unit prodbox-gateway.service could not be found.`
- Post-removal `/v1/state` on the leader confirmed `has_active_claim: true`
  with a `last_dns_write_at_utc` newer than the systemctl-disable moment, and
  the Route 53 record still matched the host's real public IP — i.e., the
  in-cluster gateway is now the sole DNS write owner.
- The three legacy ledger entries the sprint owned (host systemd unit,
  `install-service` CLI command, host-supervisor doctrine language) are now in
  the Completed section of `legacy-tracking-for-deletion.md`.

### Remaining Work

None.


## Sprint 4.13: Per-Test AWS Fixture Hygiene and Resource Tagging ✅

**Status**: Done
**Implementation**: `tests/integration/aws_helpers.py`, `tests/integration/test_dns_route53_aws.py`, `src/prodbox/cli/test_cmd.py`, `src/prodbox/cli/pulumi_cmd.py`, `tests/integration/test_pulumi_real.py`, `DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md`
**Docs to update**: `documents/engineering/aws_integration_environment_doctrine.md`, `documents/engineering/aws_test_environment.md`, `documents/engineering/cli_command_surface.md`, `documents/engineering/integration_fixture_doctrine.md`, `documents/engineering/unit_testing_policy.md`

### Objective

Close the janitor-era AWS cleanup model by moving cleanup ownership into the named Route 53 and
Pulumi test flows and leaving no session sweep, standalone janitor CLI, or host cron supervision
on the supported path.

### Deliverables

- The `dns-aws` suite owns a fresh Route 53 hosted zone per test through
  `tests/integration/aws_helpers.py` and always deletes it in fixture teardown.
- The supported AWS stack lifecycle closes through named Pulumi surfaces:
  `prodbox pulumi test-resources` and `prodbox pulumi test-destroy --yes`.
- No session-scoped AWS sweep, standalone janitor CLI, or host cron supervision remains on the
  supported architecture.
- Cleanup and removal details for the deleted tag-based and janitor-era harness pieces live in
  `legacy-tracking-for-deletion.md`, not in the active implementation path.

### Validation

1. `poetry run prodbox check-code`
2. `poetry run prodbox test unit`
3. `poetry run prodbox test integration dns-aws`
4. `poetry run prodbox test integration pulumi`
5. `poetry run prodbox test all`

### Current Validation State

- `poetry run prodbox test integration dns-aws` is the surviving Route 53 fixture-owned proof
  surface; `tests/integration/aws_helpers.py` creates and deletes one fresh hosted zone per test.
- `poetry run prodbox test integration pulumi` and the aggregate `poetry run prodbox test all`
  flow close AWS-backed stack lifecycle through explicit Pulumi-managed create/destroy commands.
- `tests/integration/conftest.py` does not expose any session-scoped AWS sweep fixture, and
  `poetry run prodbox aws --help` no longer includes any standalone janitor subcommand.
- `legacy-tracking-for-deletion.md` records the removed tag-based and janitor-era cleanup
  surfaces as completed cleanup work rather than active supported implementation.

### Remaining Work

None.


## Sprint 4.14: Full Cluster Delete, StorageClass Reset, and Reinstall Rebinding ✅

**Status**: Done
**Implementation**: `src/prodbox/cli/rke2.py`, `src/prodbox/cli/dag_builders.py`, `src/prodbox/cli/interpreter.py`, `src/prodbox/lib/prodbox_k8s.py`, `tests/integration/test_prodbox_lifecycle.py`
**Docs to update**: `documents/engineering/cli_command_surface.md`, `documents/engineering/effectful_dag_architecture.md`, `documents/engineering/prerequisite_doctrine.md`, `documents/engineering/storage_lifecycle_doctrine.md`

### Objective

Replace remnant-preserving cleanup with full cluster delete/install semantics while preserving the
configured manual PV host root plus the repo-local `.prodbox-state/` retained chart-state root and
proving deterministic rebinding after reinstall.

### Deliverables

- `prodbox rke2 delete --yes` wipes all managed cluster remnants other than the configured manual
  PV host root plus the repo-local `.prodbox-state/` retained chart-state root.
- `prodbox rke2 install` creates the `manual` StorageClass and deletes every other StorageClass.
- Lifecycle validation proves that retained PVCs automatically rebind to the intended PVs after
  full cluster delete plus reinstall.
- Cleanup/reporting text describes the preserved PV-content root, the preserved retained chart-state
  root, and the data-loss boundary precisely.

### Validation

1. `poetry run prodbox rke2 install`
2. `poetry run prodbox test integration lifecycle`
3. `poetry run prodbox rke2 delete --yes`
4. Reinstall proof: `poetry run prodbox rke2 install`
5. Rebinding proof: verify PVC/PV names and bindings are stable after reinstall
6. `poetry run prodbox check-code`

### Closure Validation (2026-04-13)

- `poetry run prodbox rke2 delete --yes` passed on April 13, 2026 and preserved exactly two roots:
  `/home/matthewnowak/prodbox/.data` and `/home/matthewnowak/prodbox/.prodbox-state`.
- `poetry run prodbox rke2 install` passed on April 13, 2026 in `6m 40s` and returned the host to
  the supported RKE2 state.
- The lifecycle integration suite passed inside the April 13, 2026 aggregate rerun
  (`tests/integration/test_prodbox_lifecycle.py`: 2 passed in `16m 10s`), proving retained PVC/PV
  rebinding across full delete plus reinstall.
- The April 13 aggregate rerun also passed the chart-storage and chart-platform suites and finished
  at `CLASSIFICATION=ready-for-external-proof`, which is consistent with the `manual` StorageClass
  recreate-and-rebind contract on the supported path.
- `poetry run prodbox check-code` passed on April 13, 2026 after the lifecycle closure work.

### Remaining Work

None.

## Sprint 4.15: Pulumi-Owned AWS Test Stack Lifecycle and Auto-Teardown ✅

**Status**: Done
**Implementation**: `src/prodbox/cli/pulumi_cmd.py`, `src/prodbox/cli/test_cmd.py`, `src/prodbox/cli/dag_builders.py`, `src/prodbox/lib/aws_test_stack.py`, `src/prodbox/infra/aws_test_stack_program.py`, `tests/integration/test_pulumi_real.py`, `tests/integration/test_ha_rke2_aws.py`
**Docs to update**: `documents/engineering/aws_integration_environment_doctrine.md`, `documents/engineering/aws_test_environment.md`, `documents/engineering/cli_command_surface.md`, `documents/engineering/effectful_dag_architecture.md`, `documents/engineering/integration_fixture_doctrine.md`, `documents/engineering/unit_testing_policy.md`

### Objective

Make Pulumi the sole owner of AWS-backed test resource provisioning, inspection, and teardown, and
wire that destroy path directly into `prodbox rke2 delete --yes` before the local MinIO backend is
removed.

### Deliverables

- All AWS test resources needed for the supported HA validation path are created and destroyed only
  through Pulumi; no canonical ownership, expiry, or safe-delete tag contract remains on the
  supported path.
- `prodbox pulumi test-resources` reports the Pulumi-managed AWS test resources and backend state
  for the currently selected test stack.
- `prodbox pulumi test-destroy --yes` destroys the Pulumi-managed AWS test stack and leaves the
  dedicated MinIO backend bucket easy to inspect for leaked objects.
- `prodbox rke2 delete --yes` invokes the same Pulumi destroy path automatically before it removes
  the local cluster that hosts the MinIO backend.
- The cleanup ledger no longer treats janitor-era cleanup helpers, tag-sweep helpers, or
  standalone final-audit helpers as pending supported-path residue.

### Validation

1. `poetry run prodbox check-code`
2. `poetry run prodbox rke2 delete --yes`
3. `rm -f prodbox-config.json`
4. `poetry run prodbox rke2 install`
5. `poetry run prodbox config show`
6. `poetry run prodbox config validate`
7. `poetry run prodbox pulumi test-resources`
8. `poetry run prodbox test integration pulumi`
9. `poetry run prodbox test integration ha-rke2-aws`
10. `poetry run prodbox pulumi test-destroy --yes`

### Current Validation State

- `poetry run prodbox check-code` passed on April 15, 2026 after the destructive-rerun fixes and lifecycle status refresh.
- `poetry run prodbox rke2 delete --yes`, `rm -f prodbox-config.json`, `poetry run prodbox rke2 install`, `poetry run prodbox config show`, and `poetry run prodbox config validate` passed on April 13, 2026 from the missing compiled-config baseline.
- `poetry run prodbox pulumi test-resources` passed on April 14, 2026 and created the canonical `aws-test` stack with three Pulumi-managed EC2 nodes in separate AZs.
- The Pulumi lifecycle proof executed by `poetry run prodbox test integration pulumi` passed inside the canonical `poetry run prodbox test all` rerun on April 14, 2026 as `tests/integration/test_pulumi_real.py::test_pulumi_test_stack_resources_and_destroy_are_idempotent`.
- The same shared AWS test stack also supported the HA-over-SSH proof during the April 14, 2026 aggregate rerun as `tests/integration/test_ha_rke2_aws.py::test_ha_rke2_bootstrap_succeeds_on_three_pulumi_managed_nodes`.
- `poetry run prodbox test integration lifecycle` passed on April 15, 2026 (`2 passed` in `16m 06s`), proving that the internal `rke2 install` path now re-authenticates Harbor image publication correctly after `docker system prune -af --volumes`.
- `poetry run prodbox pulumi test-destroy --yes` passed on April 14, 2026 and again inside the April 15, 2026 aggregate postflight, each time reporting no AWS residue plus an empty backend bucket `prodbox-test-pulumi-backends`.
- `poetry run prodbox rke2 delete --yes`, `docker system prune -af --volumes`, `sudo rm -rf .data`,
  and `poetry run prodbox test all` passed on April 15, 2026; the aggregate rerun finished in
  `1h 49m 7s`, re-proved the EKS, Pulumi, and HA-over-SSH suites from the wiped baseline, and
  auto-destroyed both `aws-eks-test` and `aws-test` with no Pulumi-managed AWS residue.

### Remaining Work

None.

## Documentation Requirements

**Engineering docs to create/update:**

- `documents/engineering/storage_lifecycle_doctrine.md` - configured manual PV root, `manual`-only
  StorageClass lifecycle, full cluster delete semantics, and delete/reinstall rebinding contract.
- `documents/engineering/helm_chart_platform_doctrine.md` - chart storage consumes the configured
  manual PV host root and treats it as PV-content-only storage.
- `documents/engineering/cli_command_surface.md` - `rke2 install|delete`, `pulumi test-resources`,
  and `pulumi test-destroy --yes` command matrix and destructive confirmation rules.
- `documents/engineering/prerequisite_doctrine.md` - Ubuntu 24.04 gate, install/delete
  prerequisites, and remnant-free delete semantics.
- `documents/engineering/effectful_dag_architecture.md` - host-owned local cluster lifecycle,
  remote HA-over-SSH sequencing, and pre-delete Pulumi destroy ordering.
- `documents/engineering/unit_testing_policy.md` - lifecycle validation from the install/delete
  baseline plus the named `ha-rke2-aws` suite.
- `documents/engineering/aws_integration_environment_doctrine.md` - Pulumi-exclusive AWS test
  lifecycle, local-cluster-first MinIO backend, and destroy ordering.
- `documents/engineering/aws_test_environment.md` - three separate-AZ `Ubuntu 24.04 LTS` EC2 test
  topology plus the dedicated MinIO backend bucket.
- `documents/engineering/integration_fixture_doctrine.md` - removal of tag-based AWS sweep helpers
  from the supported architecture in favor of Pulumi-owned teardown.

**Product docs to create/update:**

- None.

**Cross-references to add:**

- Keep `README.md`, `00-overview.md`, `system-components.md`, and the legacy ledger aligned with
  the active lifecycle, AWS teardown, and storage work.

## Related Documents

- [README.md](README.md)
- [00-overview.md](00-overview.md)
- [system-components.md](system-components.md)
- [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md)
