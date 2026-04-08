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
2. One repository-root `.env` for external auth and non-secret configuration; cluster-internal
   secrets are auto-generated and injected via K8s Secrets.
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
| AWS auth/config | Repository-root `.env` (external auth and non-secret config only) read by `Settings()` | Repository root |
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

Open, incomplete, or blocked:

- Sprint 4.3 is still open because the live cluster still lacks the intended public-edge
  resources: `prodbox host public-edge` currently reports Route 53 access denied for hosted-zone
  diagnostics, no `traefik-system` service, and no `certificate` CRD, while
  `poetry run prodbox test integration charts-vscode` still times out against the public host.
- Sprint 4.4 is still open because the supported host has not installed
  `prodbox-gateway.service` yet, even though the repo-local gateway changes plus the canonical
  `gateway-daemon` and `gateway-pods` suites now pass.
- Public-host closure for `vscode.resolvefintech.com` is not complete because the authoritative
  Route 53 record and the live public `80/443` path still need to be reproved against the active
  WAN edge from the canonical external-only validation path.
- Sprint 4.2 closure is blocked in the current AWS environment because the active identity cannot
  rerun the authoritative `dns-aws`, `pulumi`, and `public-dns` validations against the configured
  hosted-zone path, and the local bootstrap-disabled Pulumi reconcile path also still needs a
  configured Pulumi secrets passphrase in the current shell.
- The cluster now uses one StorageClass named `manual` with provisioner
  `kubernetes.io/no-provisioner`; the previous names (`prodbox-local-retain` and
  `prodbox-chart-null-storage`) have been consolidated.
- The storage path scheme is now the 5-segment
  `.data/<namespace>/<release>/<workload>/<ordinal>/<claim>`.
- HA-mode deployment with pod anti-affinity is now implemented; dev mode
  (`PRODBOX_DEV_MODE=true`) suppresses anti-affinity while retaining replica counts.
- `.env` now carries only external auth and non-secret configuration. Cluster-internal
  secrets are auto-generated at chart deploy time and persisted in `.data/`. IP addressing
  is always auto-discovered. `KUBECONFIG` uses the default `~/.kube/config`. `PULUMI_STACK`
  is hardcoded to `home`.
- A full clean-room rerun that ends with zero remaining legacy items has not yet completed.

## Current-Environment Rerun Blockers

- `poetry run prodbox check-code` and `poetry run prodbox test unit` passed on April 7, 2026
  after Sprint 4.6 configuration simplification (991 unit tests).
- `poetry run prodbox test integration charts-platform`,
  `poetry run prodbox test integration gateway-daemon`, and
  `poetry run prodbox test integration gateway-pods` all passed on April 6, 2026.
- `poetry run prodbox host public-edge` currently fails because the active AWS identity lacks
  `route53:GetHostedZone`, the live cluster has no `traefik-system` service, and the cluster still
  lacks the `certificate` CRD required by cert-manager.
- `PULUMI_ENABLE_DNS_BOOTSTRAP=false poetry run prodbox pulumi preview` is blocked because
  `PULUMI_CONFIG_PASSPHRASE` or `PULUMI_CONFIG_PASSPHRASE_FILE` is not set in the current shell.
- `systemctl` currently reports `prodbox-gateway.service` as not found on the supported host, so
  Sprint 4.4 still lacks live host-supervision proof even though the process and pod suites pass.
- `poetry run prodbox test integration dns-aws` is blocked because the active AWS identity lacks
  `route53:CreateHostedZone`.
- `poetry run prodbox pulumi up --yes` is blocked because the active AWS identity lacks
  `route53:GetHostedZone` for the configured hosted zone path.
- `poetry run prodbox test integration charts-vscode` still fails because every HTTPS/TLS/auth
  probe to `https://vscode.resolvefintech.com` times out.
- `poetry run prodbox test integration public-dns` is blocked because the active AWS identity lacks
  `route53:GetHostedZone` for `ROUTE53_ZONE_ID`.
- Phase 5 public-host closure remains blocked until the live public edge is reproved externally on
  the canonical `Traefik -> vscode-nginx -> Keycloak` path and the authoritative Route 53 record
  is shown current for the active WAN IP at rerun time.

## Hard Constraints

- The only supported public CLI is `prodbox`.
- The repository-root `.env` file carries external auth (AWS credentials) and non-secret
  configuration (Route 53 zone ID, domain FQDNs, ACME email, DNS bootstrap flags, dev-mode
  flag). Cluster-internal secrets are auto-generated at chart deploy time and injected via K8s
  Secrets; they must not appear in `.env`. IP addressing (MetalLB pool, ingress LB IP) is always
  auto-discovered from the host LAN; static IP overrides in `.env` are not supported.
  `KUBECONFIG` is not configured via `.env`; the default `~/.kube/config` is always used.
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
