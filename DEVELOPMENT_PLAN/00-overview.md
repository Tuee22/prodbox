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
2. One supported host environment: `Ubuntu 24.04 LTS` with systemd.
3. One host-owned `prodbox rke2 install|delete --yes|status|start|stop|restart|logs` surface for
   the RKE2 cluster itself.
4. One repository-root `prodbox-config.dhall` auto-compiled idempotently to
   `prodbox-config.json` whenever supported commands load settings and the compiled artifact is
   missing or stale; the Dhall config explicitly declares the manual PV host root and defaults it
   to the repository `.data/` directory; no `.env` file.
5. One distributed gateway runtime that lives entirely inside the RKE2 cluster as a Kubernetes
   workload, with leader election, partition tolerance, and Route 53 write ownership.
6. One retained PV host-path model rooted at the configured manual PV root, defaulting to
   `.data/<namespace>/<release>/<workload>/<ordinal>/<claim>` and reserved purely for PV content.
7. Deterministic PVC/PV rebinding after cluster delete/reinstall so ephemeral teardown and spin-up
   do not lose retained state, while non-PV retained chart state lives separately under the
   repo-local `.prodbox-state/<namespace>/` root and is preserved across full cluster delete.
8. One supported cluster-backed `vscode` delivery path.
9. One named validation command per major surface.
10. One explicit ledger for every compatibility or cleanup item still slated for removal.
11. One cluster-wide StorageClass named `manual` of type `kubernetes.io/no-provisioner`; cluster
    install recreates `manual` and deletes every other StorageClass.
12. All cluster services deployed via Helm; Pulumi orchestrates infrastructure Helm releases, the
    `prodbox charts` platform manages application Helm releases.
13. AWS fixture cleanup is harness-owned: every AWS-mutating test begins by sweeping any
    pre-existing tagged fixture resources, and no standalone host cron or long-running janitor
    job owns AWS cleanup.

## Clean-Room Sequence

| Phase | Focus | Closure Result |
|-------|-------|----------------|
| 0 | Planning and Documentation Topology | The plan becomes the single roadmap and status source |
| 1 | Runtime, CLI, and AWS Validation Foundations | Core CLI, the Ubuntu 24.04 support gate, host-owned RKE2 install/delete, and AWS auth doctrine are established |
| 2 | Distributed Gateway Runtime and DNS Ownership | The distributed gateway, TLA+ entrypoint, and Route 53 write capability exist |
| 3 | Chart Platform and Cluster-Backed `vscode` Delivery | Deterministic retained storage and the namespace-local stack are canonical |
| 4 | Lifecycle Hardening and Canonical-Path Cleanup | Cluster delete/install lifecycle, PV-root doctrine, and compatibility cleanup are canonical |
| 5 | Public Hostname Closure and Authoritative External Proof | Public DNS, TLS, ingress, and Keycloak redirect proof are canonicalized |
| 6 | Final Clean-Room Rerun and Zero-Legacy Handoff | The full rerun passes from cluster delete plus missing compiled config and the legacy backlog is empty |

## Architecture Summary

| Surface | Canonical Path | Authority |
|---------|----------------|-----------|
| CLI control plane | `poetry run prodbox <command>` | Repository worktree |
| Supported host runtime | `Ubuntu 24.04 LTS` with systemd | `prodbox` supported-host gate |
| AWS auth/config | Repository-root `prodbox-config.dhall`, auto-compiled idempotently to `prodbox-config.json` by canonical settings loads and read by `Settings()` | Repository root |
| RKE2 lifecycle | `prodbox rke2 install`, `status`, `delete --yes` | `prodbox` CLI for host-owned cluster lifecycle, service enablement, and full delete that preserves only the configured PV root plus the repo-local `.prodbox-state/` retained chart-state root |
| Pulumi infrastructure | `prodbox pulumi ...` | `src/prodbox/infra/` plus Route 53 for MetalLB, Traefik, cert-manager, and issuer/bootstrap ownership |
| Gateway startup | `prodbox gateway start` (in-pod entrypoint) | `src/prodbox/gateway_daemon.py` deployed via `prodbox charts` |
| Gateway steady state | In-cluster gateway pod under leader election | Kubernetes Deployment/StatefulSet managed by `prodbox charts` |
| Gateway DNS writes | Gateway `dns_write_gate` | In-cluster gateway pod (elected leader) |
| Public edge ingress | `MetalLB -> Traefik -> chart Ingress` | Pulumi plus cluster runtime |
| Namespace-local auth proxy | `vscode-nginx` inside the `vscode` chart | Chart platform |
| Chart delivery | `prodbox charts list|status|deploy|delete` | Chart platform registry |
| Supported app delivery | Namespace-local `keycloak-postgres -> keycloak -> vscode` stack | Chart platform |
| Retained non-PV chart state | Repo-local `.prodbox-state/<namespace>/` | `prodbox charts` helpers plus the `rke2 delete --yes` preservation contract |
| Validation | Named `prodbox test ...`, `prodbox tla-check`, `prodbox check-code` | Repository-owned commands |
| AWS fixture cleanup | Harness-owned pre-test sweep inside each AWS-mutating test plus canonical fixture tags | Test harness plus canonical AWS tags |
| Stable doctrine | `documents/engineering/` | Governed docs |
| Status and blockers | `DEVELOPMENT_PLAN/` | This plan suite |

## Current Repository State

Completed and present in the repository:

- Repository-wide status, blocker, and cleanup tracking live in this plan suite.
- Runtime and CLI foundations exist: explicit Click command groups, command ADTs, eDAG builders,
  interpreter execution, named test suites, and documentation-topology guard coverage.
- Real-system validation exists for AWS foundation, EKS, Route 53, Pulumi, gateway process mode,
  gateway pod mode, chart storage/platform, lifecycle behavior, and public DNS delegation.
- The distributed gateway implementation exists with `prodbox gateway` management commands, TLA+
  artifacts, unit coverage, and Kubernetes integration suites.
- `prodbox charts` exists as a first-class capability with deterministic retained PV naming and the
  namespace-local `keycloak-postgres -> keycloak -> vscode` stack.
- The intended public-edge stack in repository code is `MetalLB -> Traefik -> vscode` Ingress,
  with `vscode-nginx` acting only as the namespace-local auth proxy behind that edge.
- Pulumi subprocess handling injects the canonical nested-entrypoint override, and `Settings()`
  loads from `prodbox-config.json` (compiled from `prodbox-config.dhall`) via
  `Settings.from_config_json()` only.
- AWS-backed fixture helpers tag Route 53, S3, VPC, subnet, security-group, EKS, and IAM
  resources with canonical ownership/expiry/safe-delete tags, and setup helpers roll back
  partial AWS creation before fixture yield.

Open, incomplete, or blocked:

- The current lifecycle surface still assumes RKE2 is already installed on the host and still uses
  legacy reconcile/cleanup semantics rather than host-owned `install|delete` semantics.
- The supported-host gate is still Linux-generic in the current architecture summary; it must fail
  fast unless the machine is `Ubuntu 24.04 LTS`.
- The current configuration model does not yet explicitly declare the manual PV host root in
  `prodbox-config.dhall`.
- The repository still carries a mixed-purpose `.data/` narrative; the new doctrine reserves the
  configured manual PV host root purely for PV content.
- The current lifecycle proof preserves cluster remnants by design; it does not yet prove a full
  cluster delete that wipes everything except the configured PV root, recreates `manual`, deletes
  all other StorageClasses, and rebinds PVCs after reinstall.
- The final clean-room rerun has not yet been revalidated from `poetry run prodbox rke2 delete --yes`
  plus a missing `prodbox-config.json`.

The April 12, 2026 clean-room proof remains useful evidence for the prior architecture, but it no
longer closes the end state after the April 13, 2026 doctrine update.

## Current-Environment Validation Snapshot

- `poetry run prodbox rke2 delete --yes` passed on April 13, 2026 and reported preserved roots
  `/home/matthewnowak/prodbox/.data` and `/home/matthewnowak/prodbox/.prodbox-state`.
- `rm -f prodbox-config.json` removed the compiled config before the closure rerun.
- `poetry run prodbox rke2 install` passed on April 13, 2026 in `6m 40s` on `Ubuntu 24.04.4 LTS`,
  and `systemctl is-enabled rke2-server` returned `enabled`.
- `poetry run prodbox config show` and `poetry run prodbox config validate` both passed on
  April 13, 2026 and auto-regenerated `prodbox-config.json`; `config show` reported
  `storage.manual_pv_host_root=/home/matthewnowak/prodbox/.data`.
- `poetry run prodbox test all` passed on April 13, 2026 in `1h 27m 34s` from full cluster
  delete plus missing compiled config, restored the supported runtime, and ended at
  `CLASSIFICATION=ready-for-external-proof`.
- The aggregate supported test flow continues to perform the final zero-AWS-residue proof through
  `src/prodbox/lib/aws_fixture_audit.py`; it does not invoke a standalone janitor command or
  depend on host cron supervision.
- `poetry run prodbox host public-edge` passed on April 13, 2026 and reported
  `CLASSIFICATION=ready-for-external-proof`.
- `poetry run prodbox test integration public-dns` passed on April 13, 2026 (2 tests).
- `poetry run prodbox check-code` passed on April 13, 2026 after the closure work.
- `/etc/hosts` contains no `vscode.resolvefintech.com` override, and the cleanup ledger is empty.

## Hard Constraints

- The only supported public CLI is `prodbox`.
- The only supported operator environment is `Ubuntu 24.04 LTS` with systemd.
- `prodbox` owns the RKE2 cluster lifecycle itself. The supported host path is explicit cluster
  install, service enablement for reboot recovery, inspection, and destructive cluster delete.
- The repository-root `prodbox-config.dhall` is the single configuration source.
  `prodbox config compile` remains the explicit compile surface, and canonical settings loads also
  auto-compile `prodbox-config.json` idempotently when the repository-root JSON artifact is
  missing or stale.
- `prodbox-config.dhall` must explicitly provide the manual PV host root. The canonical default is
  the repository `.data/` directory.
- The configured manual PV host root is reserved purely for PV content. Cluster secrets, gateway
  mesh keys, or other non-PV retained artifacts must not live there.
- Full cluster delete preserves exactly two retained host roots: the configured manual PV host
  root for PV contents and the repo-local `.prodbox-state/` root for non-PV retained chart state.
- Cluster delete wipes every other managed cluster remnant.
- The only permitted cluster StorageClass is named `manual` with provisioner
  `kubernetes.io/no-provisioner`; cluster install recreates `manual` and deletes all other
  StorageClasses.
- PVCs may only be created by Helm charts deploying StatefulSets; no other mechanism may create
  PVCs.
- PVs must be pre-created explicitly before Helm install; implicit PVC provisioning is not
  permitted.
- Path naming under the manual PV root must remain stable across cluster delete/install cycles so
  retained PVCs automatically rebind to the intended PVs.
- No tooling or CLI command may delete the configured manual PV root as part of cluster delete.
- No prodbox daemon or cron-driven background job runs on the host. The only supported
  steady-state long-running prodbox workload is inside the RKE2 cluster as a Kubernetes workload
  managed by `prodbox charts`.
- The only supported gateway startup path is `prodbox gateway start`, invoked as the entrypoint
  of the in-cluster gateway pod.
- The only supported Route 53 ownership/update path is gateway `dns_write_gate`.
- The only supported DNS model is explicit per-subdomain Route 53 records; wildcard public DNS is
  not part of the supported architecture.
- The only supported cluster-edge ingress controller is Traefik; namespace-local `vscode-nginx` is
  an application auth proxy behind it, not a competing edge controller.
- The only supported `vscode` delivery path is the cluster-backed `prodbox charts` stack.
- The only supported validation paths are named `prodbox` commands; raw passthrough or alternate
  operator workflows are debt to remove, not supported surfaces.
- Final clean-room handoff requires a single supported rerun path from
  `poetry run prodbox rke2 delete --yes` to `poetry run prodbox test all` with no manual RKE2,
  Pulumi, Helm, or host resolver repair steps in between.
- Final clean-room handoff also requires the aggregate supported test flow to prove that no
  fixture-owned Route 53, S3, VPC, EKS, or IAM resources remain; that proof may not depend on a
  post-run standalone `prodbox aws sweep-fixtures` invocation or any host-side background AWS
  cleanup job.
- Authoritative public-host proof may not depend on `/etc/hosts` or other local resolver overrides
  for `vscode.resolvefintech.com`.
- Documents under `documents/` are stable doctrine and reference only. They do not own sprint
  histories, blocker tracking, or completion state.
- Compatibility shims, duplicate operator paths, mixed-purpose storage roots, and transitional
  naming are removal targets, not long-term architecture.

## Related Documents

- [README.md](README.md)
- [system-components.md](system-components.md)
- [phase-0-planning-documentation.md](phase-0-planning-documentation.md)
- [phase-4-lifecycle-canonical-paths.md](phase-4-lifecycle-canonical-paths.md)
- [phase-5-public-host-validation.md](phase-5-public-host-validation.md)
- [phase-6-clean-room-handoff.md](phase-6-clean-room-handoff.md)
- [../documents/engineering/README.md](../documents/engineering/README.md)
