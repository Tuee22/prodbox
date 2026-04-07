# File: DEVELOPMENT_PLAN/00-overview.md
# prodbox Development Plan - Overview

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [system-components.md](system-components.md)

> **Purpose**: Provide the architectural overview, clean-room sequence, repository state, and hard
> constraints for the prodbox development plan.

## Vision

Build a clean-room prodbox repository with:

1. One explicit `prodbox` CLI surface.
2. One repository-root `.env` authentication and configuration source.
3. One distributed gateway runtime, always-on supervision model, and Route 53 write path.
4. One chart-platform storage model rooted at `.data/<namespace>/<statefulset>/<ordinal>`.
5. One supported cluster-backed `vscode` delivery path.
6. One named validation command per major surface.
7. One explicit ledger for every compatibility or cleanup item still slated for removal.

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
| AWS auth/config | Repository-root `.env` read by `Settings()` | Repository root |
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
- `prodbox charts` exists as a first-class capability with deterministic retained storage rooted at
  `.data/<namespace>/<statefulset>/<ordinal>`.
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
- A full clean-room rerun that ends with zero remaining legacy items has not yet completed.

## Current-Environment Rerun Blockers

- `poetry run prodbox host public-edge` currently fails because Route 53 hosted-zone reads are
  denied, the live cluster has no `traefik-system` service, and the cluster does not currently
  expose the cert-manager `certificate` CRD.
- `PULUMI_ENABLE_DNS_BOOTSTRAP=false poetry run prodbox pulumi preview` is blocked because
  `PULUMI_CONFIG_PASSPHRASE` or `PULUMI_CONFIG_PASSPHRASE_FILE` is not set in the shell.
- `poetry run prodbox test integration dns-aws` is blocked because the active AWS identity lacks
  `route53:CreateHostedZone`.
- `poetry run prodbox pulumi up --yes` is blocked because the active AWS identity lacks
  `route53:GetHostedZone` for the demo hosted-zone path.
- `poetry run prodbox test integration charts-vscode` still fails because every HTTPS/TLS/auth
  probe to `https://vscode.resolvefintech.com` times out.
- `poetry run prodbox test integration public-dns` is blocked because the active AWS identity
  lacks `route53:GetHostedZone` for `ROUTE53_ZONE_ID`.
- Sprint 5.1 remains blocked by the still-open live proof work in Sprint 4.3 and Sprint 4.4 plus
  the AWS access still required for authoritative Route 53 proof reruns.

## Hard Constraints

- The only supported public CLI is `prodbox`.
- The only supported repository auth/config source is the root `.env` file.
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

## Related Documents

- [README.md](README.md)
- [system-components.md](system-components.md)
- [phase-4-lifecycle-canonical-paths.md](phase-4-lifecycle-canonical-paths.md)
- [phase-5-public-host-validation.md](phase-5-public-host-validation.md)
- [../documents/engineering/README.md](../documents/engineering/README.md)
