# File: DEVELOPMENT_PLAN/phase-4-lifecycle-canonical-paths.md
# Phase 4: Lifecycle Hardening and Canonical-Path Cleanup

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md)

> **Purpose**: Capture the lifecycle hardening work that removes cleanup-settling retries and the
> canonical-path cleanup work that leaves one supported surface per major capability.

## Phase Summary

This phase hardens `rke2 cleanup` until lifecycle validation passes without settling retries, then
removes duplicate or compatibility-only runtime, CLI, validation, and tooling paths, and closes
the remaining local edge-infrastructure automation gaps around MetalLB, Traefik, cert-manager,
always-on gateway supervision, explicit per-subdomain DNS continuity, and public-host diagnostics.
All cleanup history remains centralized in
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
**Implementation**: `src/prodbox/settings.py`, `src/prodbox/infra/__main__.py`, `src/prodbox/infra/metallb.py`, `src/prodbox/infra/ingress.py`, `src/prodbox/infra/cert_manager.py`, `src/prodbox/infra/cluster_issuer.py`, `charts/vscode/templates/ingress.yaml`, `src/prodbox/cli/host.py`, `src/prodbox/cli/dag_builders.py`, `tests/integration/test_charts_platform.py`
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
**Implementation**: `src/prodbox/gateway_daemon.py`, `src/prodbox/cli/gateway.py`, `src/prodbox/cli/interpreter.py`, `src/prodbox/settings.py`, `tests/unit/test_gateway_daemon.py`, `tests/integration/test_gateway_daemon_k8s.py`, `tests/integration/test_gateway_k8s_pods.py`
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

## Documentation Requirements

**Engineering docs to create/update:**

- `documents/engineering/aws_integration_environment_doctrine.md` - blocked AWS rerun rules and
  canonical auth ownership.
- `documents/engineering/cli_command_surface.md` - canonical command and validation paths.
- `documents/engineering/dependency_management.md` - supported local tooling doctrine.
- `documents/engineering/distributed_gateway_architecture.md` - gateway startup and DNS ownership.
- `documents/engineering/helm_chart_platform_doctrine.md` - supported chart and `vscode` paths.
- `documents/engineering/prerequisite_doctrine.md` - prerequisite registry cleanup.
- `documents/engineering/unit_testing_policy.md` - authoritative named validation paths.

**Product docs to create/update:**

- None.

**Cross-references to add:**

- Keep cleanup and compatibility ownership pointed at
  `DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md`.
