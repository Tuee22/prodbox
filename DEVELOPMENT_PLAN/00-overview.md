# File: DEVELOPMENT_PLAN/00-overview.md
# prodbox Development Plan - Overview

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [system-components.md](system-components.md), [phase-0-planning-documentation.md](phase-0-planning-documentation.md), [phase-1-runtime-cli-aws-foundations.md](phase-1-runtime-cli-aws-foundations.md), [phase-2-gateway-dns.md](phase-2-gateway-dns.md), [phase-3-chart-platform-vscode.md](phase-3-chart-platform-vscode.md), [phase-4-lifecycle-canonical-paths.md](phase-4-lifecycle-canonical-paths.md), [phase-5-public-host-validation.md](phase-5-public-host-validation.md), [phase-6-clean-room-handoff.md](phase-6-clean-room-handoff.md)

> **Purpose**: Provide the architectural overview, clean-room sequence, repository state, and hard
> constraints for the prodbox development plan.

## Vision

Build a clean-room prodbox repository with:

1. One explicit `prodbox` CLI surface.
2. One repository-root `prodbox-config.dhall` compiled to `prodbox-config.json` for all
   configuration; cluster-internal secrets are auto-generated at chart deploy time; no `.env`
   file.
3. One distributed gateway runtime, always-on supervision model, and Route 53 write path.
4. One chart-platform storage model rooted at `.data/<namespace>/<release>/<workload>/<ordinal>/<claim>`.
5. One supported cluster-backed `vscode` delivery path.
6. One named validation command per major surface.
7. One explicit ledger for every compatibility or cleanup item still slated for removal.
8. One cluster-wide StorageClass named `manual` of type `kubernetes.io/no-provisioner`; no dynamic
   provisioner is permitted.
9. All cluster services deployed via Helm; Pulumi orchestrates infrastructure Helm releases, the
   `prodbox charts` platform manages application Helm releases.
10. All stateful services deployed in HA mode by default, with pod anti-affinity suppressed in dev
    mode.
11. PVs pre-created explicitly before Helm install; PVCs created only by Helm charts deploying
    StatefulSets.

## Clean-Room Sequence

| Phase | Focus | Closure Result |
|-------|-------|----------------|
| 0 | Planning and Documentation Topology | The plan becomes the single roadmap and status source |
| 1 | Runtime, CLI, and AWS Validation Foundations | Core CLI, test surfaces, AWS auth doctrine, and real-system validation are established |
| 2 | Distributed Gateway Runtime and DNS Ownership | The distributed gateway, TLA+ entrypoint, and Route 53 write capability exist |
| 3 | Chart Platform and Cluster-Backed `vscode` Delivery | Deterministic retained storage and the namespace-local stack are canonical |
| 4 | Lifecycle Hardening and Canonical-Path Cleanup | Cleanup is stable without settling shims and duplicate paths are removed |
| 5 | Public Hostname Closure and Authoritative External Proof | Public DNS, TLS, ingress, and Keycloak redirect proof are canonicalized |
| 6 | Final Clean-Room Rerun and Zero-Legacy Handoff | The full clean-room rerun passes and the legacy backlog is empty |

## Architecture Summary

| Surface | Canonical Path | Authority |
|---------|----------------|-----------|
| CLI control plane | `poetry run prodbox <command>` | Repository worktree |
| AWS auth/config | Repository-root `prodbox-config.dhall` compiled to `prodbox-config.json`, read by `Settings()` | Repository root |
| RKE2 lifecycle | `prodbox rke2 ensure`, `status`, `cleanup --yes` | `prodbox` CLI |
| Pulumi infrastructure | `prodbox pulumi ...` | `src/prodbox/infra/` plus Route 53 |
| Gateway startup | `prodbox gateway start` | `src/prodbox/gateway_daemon.py` |
| Gateway steady state | Supervised `prodbox gateway start <config.json>` | Host service or pod supervisor |
| Gateway DNS writes | Gateway `dns_write_gate` | Distributed gateway runtime |
| Public edge ingress | `MetalLB -> Traefik -> chart Ingress` | Pulumi plus cluster runtime |
| Namespace-local auth proxy | `vscode-nginx` inside the `vscode` chart | Chart platform |
| Chart delivery | `prodbox charts list|status|deploy|delete` | Chart platform registry |
| Supported app delivery | Namespace-local `keycloak-postgres -> keycloak -> vscode` stack | Chart platform |
| Validation | Named `prodbox test ...`, `prodbox tla-check`, `prodbox check-code` | Repository-owned commands |
| Stable doctrine | `documents/engineering/` | Governed docs |
| Status and blockers | `DEVELOPMENT_PLAN/` | This plan suite |

## Current Repository State

Completed and present in the repository:

- Repository-wide status, blocker, and cleanup tracking now live in this plan suite.
- Runtime and CLI foundations exist: explicit Click command groups, command ADTs, eDAG builders,
  interpreter execution, named test suites, and documentation-topology guard coverage.
- Real-system validation exists for AWS foundation, EKS, Route 53, Pulumi, gateway process mode,
  gateway pod mode, chart storage/platform, lifecycle behavior, and public DNS delegation.
- Distributed gateway implementation exists with `prodbox gateway` management commands, TLA+
  artifacts, unit coverage, and Kubernetes integration suites.
- `prodbox charts` exists as a first-class capability with deterministic retained storage currently
  rooted at `.data/<namespace>/<statefulset>/<ordinal>`. The intended storage path scheme is
  `.data/<namespace>/<release>/<workload>/<ordinal>/<claim>`, to be adopted by Sprint 4.5.
- The namespace-local `keycloak-postgres -> keycloak -> vscode` stack exists, and the supported
  cluster auth model is nginx OIDC plus local Keycloak users.
- `prodbox rke2 cleanup --yes` uses namespace-first cleanup and preserves retained storage kinds
  for deterministic rebind.
- Gateway startup is canonical through `prodbox gateway start`; the legacy Poetry `daemon`
  entrypoint, compatibility container wrapper, and direct daemon wrapper path are gone.
- Route 53 ownership and update is canonical through gateway `dns_write_gate`; the old CLI/DDNS
  timer path and repo-tracked systemd units are gone.
- The interpreter and summary layer expose one canonical structured DAG outcome model without the
  old command-summary compatibility bridge.
- Pulumi subprocess handling injects the canonical nested-entrypoint override, and `Settings()`
  reads `.env` only from the fixed repository root.
- The canonical certificate path is Let's Encrypt HTTP-01 through `letsencrypt-http01`.
- Settings can now derive `METALLB_POOL` and `INGRESS_LB_IP` from the active LAN interface when
  those values are left blank, while still surfacing the detected interface, IPv4, and subnet in
  the effective settings model.
- The canonical infrastructure path now deploys cert-manager directly, wires the cluster issuer
  after cert-manager plus Traefik, and can skip Route 53 bootstrap with
  `PULUMI_ENABLE_DNS_BOOTSTRAP=false` when only local edge recovery is needed.
- `prodbox host public-edge` now exists as the named diagnostic command for public-edge ownership,
  Route 53 record state, Traefik service IP, ingress-class drift, and certificate readiness.
- `prodbox gateway install-service` now exists as the canonical host-supervision installer, and
  generated gateway config plus `gateway status` now expose `dns_write_gate` and DDNS health.
- The `charts-platform` integration fixture now clears retained `.data/vscode` state before live
  setup so reruns do not inherit stale Keycloak/Postgres credentials from previous deployments.
- Gateway daemon shutdown now tracks and awaits per-connection reader tasks so the canonical
  process-mode integration suite no longer leaks sockets/transports at teardown.
- The intended public-edge stack in repository code is `MetalLB -> Traefik -> vscode` Ingress,
  with `vscode-nginx` acting only as the namespace-local auth proxy behind that edge.
- The external public-host `charts-vscode` suite now runs without cluster prerequisite gates or an
  `rke2 ensure` preflight.
- `prodbox-config-types.dhall` exists as the version-controlled Dhall schema;
  `prodbox config init|compile|show|validate` commands exist; `Settings` loads from
  `prodbox-config.json` via `from_config_json()`.
- `pydantic-settings` dependency removed; `Settings` uses `BaseModel` from plain `pydantic`.
- `aws_auth.py` module deleted; all AWS credential access flows through `Settings`.
- `prodbox env` command group removed; replaced by `prodbox config`.
- Subprocess environments built from explicit `_base_subprocess_env()` allowlist; `os.environ`
  inheritance eliminated.
- AWS fixture leak prevention is in place: a session-scoped autouse `sweep_expired_aws_fixtures`
  fixture in `tests/integration/conftest.py` runs a pre-test janitor sweep at the start of every
  integration test session; `prodbox aws sweep-fixtures` CLI command provides an out-of-band
  entrypoint; an hourly cron entry supervises expired resource cleanup between test runs.

Open, incomplete, or blocked:

- Sprint 4.3 is active: Pulumi deployed the full infrastructure stack (MetalLB, Traefik,
  cert-manager, ClusterIssuer, Route 53) on April 9, 2026. The `vscode` chart stack is deployed
  and the local ingress path works. Router port forwarding still routes ports 80/443 to the host
  (`192.168.2.79`) instead of the MetalLB ingress (`192.168.2.240`); `charts-vscode` tests fail
  with connection refused until this is updated.
- Sprint 4.4 is blocked on gateway service install: all gateway integration suites pass, but
  `prodbox-gateway.service` has not been installed on the host.
- The cluster now uses one StorageClass named `manual` with provisioner
  `kubernetes.io/no-provisioner`; the previous names (`prodbox-local-retain` and
  `prodbox-chart-null-storage`) have been consolidated.
- The storage path scheme is now the 5-segment
  `.data/<namespace>/<release>/<workload>/<ordinal>/<claim>`.
- HA-mode deployment with pod anti-affinity is now implemented; dev mode
  (`PRODBOX_DEV_MODE=true`) suppresses anti-affinity while retaining replica counts.
- Sprint 4.6 removed cluster-internal secrets, IP overrides, `KUBECONFIG`, and `PULUMI_STACK`
  from the Settings surface. Sprints 4.7-4.9 replaced `.env` with a Dhall config file as
  the single configuration source and enforced subprocess credential isolation.
- A full clean-room rerun that ends with zero remaining legacy items has not yet completed.

## Current-Environment Rerun Blockers

- `poetry run prodbox check-code` and `poetry run prodbox test unit` passed on April 9, 2026
  (953 unit tests, 17 non-integration CLI tests).
- Live cluster re-established on April 9, 2026 with RKE2, MetalLB, Traefik, cert-manager, and
  `letsencrypt-http01` ClusterIssuer via Pulumi (`PULUMI_CONFIG_PASSPHRASE=""`).
- `prodbox-config.dhall` and `prodbox-config.json` created from system credentials (Route 53 zone
  `Z07495372G135SKEMQJZU`, ACME email `matt@resolvefintech.com`).
- IAM policy `prodbox-integration-tests` attached to `bathurst-resolvefintech-dns` with Route 53,
  S3, EC2, IAM, and EKS permissions. All AWS-backed suites passed on April 9, 2026.
- 1016/1024 tests passing. The 8 `charts-vscode` tests fail with connection refused because
  router port forwarding routes 80/443 to the host (`192.168.2.79`) instead of MetalLB ingress
  (`192.168.2.240`).
- Phase 5 public-host closure remains blocked until router port forwarding is updated and Let's
  Encrypt cert issuance completes.

## Hard Constraints

- The only supported public CLI is `prodbox`.
- The repository-root `prodbox-config.dhall` is the single configuration source. It is compiled
  to `prodbox-config.json` by `prodbox config compile` and read by `Settings()`. Both files are
  gitignored. Cluster-internal secrets are auto-generated at chart deploy time and persisted in
  `.data/`; they do not appear in the config file. IP addressing (MetalLB pool, ingress LB IP)
  is always auto-discovered from the host LAN. `KUBECONFIG` always uses the default
  `~/.kube/config`. Subprocess environments are constructed explicitly from configuration; no
  credentials are inherited from `os.environ`.
- The only supported gateway startup path is `prodbox gateway start`.
- The only supported host-service install path for gateway supervision is
  `prodbox gateway install-service`.
- The supported public-host path requires the gateway daemon to run continuously under
  supervision; ad hoc manual invocation is not a supported steady state.
- The only supported Route 53 ownership/update path is gateway `dns_write_gate`.
- The only supported DNS model is explicit per-subdomain Route 53 records; wildcard public DNS is
  not part of the supported architecture.
- The only supported cluster-edge ingress controller is Traefik; namespace-local `vscode-nginx` is
  an application auth proxy behind it, not a competing edge controller.
- The only supported `vscode` delivery path is the cluster-backed `prodbox charts` stack.
- The only supported validation paths are named `prodbox` commands; raw passthrough or alternate
  operator workflows are debt to remove, not supported surfaces.
- Documents under `documents/` are stable doctrine and reference only. They do not own sprint
  histories, blocker tracking, or completion state.
- Compatibility shims, duplicate operator paths, competing ingress controllers, and transitional
  naming are removal targets, not long-term architecture.
- The only permitted cluster StorageClass is named `manual` with provisioner
  `kubernetes.io/no-provisioner`; bootstrap must fail if a chart requests a dynamic provisioner.
- PVCs may only be created by Helm charts deploying StatefulSets; no other mechanism may create
  PVCs.
- PVs must be pre-created explicitly before Helm install; implicit PVC provisioning is not
  permitted.
- All cluster services are deployed via Helm. Pulumi orchestrates infrastructure-layer Helm
  releases (MetalLB, Traefik, cert-manager). The `prodbox charts` platform manages
  application-layer Helm releases.
- All stateful services must be deployed in HA mode (multiple replicas with pod anti-affinity);
  dev mode suppresses anti-affinity but retains the multi-replica default.
- The retained storage path scheme is
  `.data/<namespace>/<release>/<workload>/<ordinal>/<claim>`. Path naming must be stable across
  teardown/rebuild cycles so data survives cluster down and cluster up.
- No tooling or CLI command is permitted to delete `.data/` itself.
- `.data/` must appear in both `.gitignore` and `.dockerignore`.

## Related Documents

- [README.md](README.md)
- [system-components.md](system-components.md)
- [phase-0-planning-documentation.md](phase-0-planning-documentation.md)
- [phase-4-lifecycle-canonical-paths.md](phase-4-lifecycle-canonical-paths.md)
- [phase-5-public-host-validation.md](phase-5-public-host-validation.md)
- [phase-6-clean-room-handoff.md](phase-6-clean-room-handoff.md)
- [../documents/engineering/README.md](../documents/engineering/README.md)
