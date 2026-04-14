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
2. One supported local operator environment: `Ubuntu 24.04 LTS` with systemd.
3. One host-owned `prodbox rke2 install|delete --yes|status|start|stop|restart|logs` surface for
   the local RKE2 cluster that runs on the test host.
4. One SSH-driven HA RKE2 deployment path for AWS integration validation, targeting exactly three
   Pulumi-managed `Ubuntu 24.04 LTS` EC2 instances in separate availability zones.
5. One repository-root `prodbox-config.dhall` auto-compiled idempotently to
   `prodbox-config.json` whenever supported commands load settings and the compiled artifact is
   missing or stale; the Dhall config explicitly declares the manual PV host root and defaults it
   to the repository `.data/` directory; no `.env` file.
6. One local-cluster-first Pulumi backend model: the host machine boots the local RKE2 cluster,
   runs MinIO there, and stores AWS test-stack state in a dedicated bucket named
   `prodbox-test-pulumi-backends`.
7. One distributed gateway runtime that lives entirely inside the RKE2 cluster as a Kubernetes
   workload, with leader election, partition tolerance, and Route 53 write ownership.
8. One retained PV host-path model rooted at the configured manual PV root, defaulting to
   `.data/<namespace>/<release>/<workload>/<ordinal>/<claim>` and reserved purely for PV content.
9. Deterministic PVC/PV rebinding after cluster delete/reinstall so ephemeral teardown and spin-up
   do not lose retained state, while non-PV retained chart state lives separately under the
   repo-local `.prodbox-state/<namespace>/` root and is preserved across full cluster delete.
10. One supported cluster-backed `vscode` delivery path.
11. One named validation command per major surface.
12. One explicit ledger for every compatibility or cleanup item still slated for removal.
13. One cluster-wide StorageClass named `manual` of type `kubernetes.io/no-provisioner`; cluster
    install recreates `manual` and deletes every other StorageClass.
14. All cluster services are deployed via Helm; Pulumi orchestrates infrastructure Helm releases
    and is the exclusive provisioner and deprovisioner for AWS-backed test resources.
15. No tag-based AWS janitor, pre-test sweep contract, or standalone host cleanup worker exists on
    the supported path.

## Clean-Room Sequence

| Phase | Focus | Closure Result |
|-------|-------|----------------|
| 0 | Planning and Documentation Topology | The plan becomes the single roadmap and status source |
| 1 | Runtime, CLI, and AWS Validation Foundations | Core CLI, the Ubuntu 24.04 support gate, host-owned local RKE2 install/delete, the local-cluster-first MinIO backend, and the three-node HA-over-SSH AWS validation path are established |
| 2 | Distributed Gateway Runtime and DNS Ownership | The distributed gateway, TLA+ entrypoint, and Route 53 write capability exist |
| 3 | Chart Platform and Cluster-Backed `vscode` Delivery | Deterministic retained storage and the namespace-local stack are canonical |
| 4 | Lifecycle Hardening and Canonical-Path Cleanup | Cluster delete/install lifecycle, PV-root doctrine, Pulumi-owned AWS test teardown, and canonical cleanup ownership are established |
| 5 | Public Hostname Closure and Authoritative External Proof | Public DNS, TLS, ingress, and Keycloak redirect proof are canonicalized |
| 6 | Final Clean-Room Rerun and Zero-Legacy Handoff | The full rerun passes from local cluster delete plus missing compiled config through local backend restore, remote HA validation, final Pulumi destroy, and an empty legacy backlog |

## Architecture Summary

| Surface | Canonical Path | Authority |
|---------|----------------|-----------|
| CLI control plane | `poetry run prodbox <command>` | Repository worktree |
| Supported host runtime | `Ubuntu 24.04 LTS` with systemd | `prodbox` supported-host gate |
| AWS auth/config | Repository-root `prodbox-config.dhall`, auto-compiled idempotently to `prodbox-config.json` by canonical settings loads and read by `Settings()` | Repository root |
| Local RKE2 lifecycle | `prodbox rke2 install`, `status`, `delete --yes` | `prodbox` CLI for host-owned local cluster lifecycle, service enablement, and full delete that preserves only the configured PV root plus the repo-local `.prodbox-state/` retained chart-state root |
| Remote HA RKE2 validation | `prodbox pulumi test-resources` plus SSH-driven `prodbox` RKE2 bootstrap | Pulumi provisions three EC2 instances in separate AZs; `prodbox` orchestrates remote HA install over SSH |
| Pulumi backend state | MinIO bucket `prodbox-test-pulumi-backends` on the local RKE2 cluster | Local cluster bootstrap owns backend availability before any remote AWS test stack exists |
| Pulumi infrastructure | `prodbox pulumi ...` | `src/prodbox/infra/` plus local MinIO-backed Pulumi state plus AWS test stacks |
| Gateway startup | `prodbox gateway start` (in-pod entrypoint) | `src/prodbox/gateway_daemon.py` deployed via `prodbox charts` |
| Gateway steady state | In-cluster gateway pod under leader election | Kubernetes Deployment or StatefulSet managed by `prodbox charts` |
| Gateway DNS writes | Gateway `dns_write_gate` | In-cluster gateway pod (elected leader) |
| Public edge ingress | `MetalLB -> Traefik -> chart Ingress` | Pulumi plus cluster runtime |
| Namespace-local auth proxy | `vscode-nginx` inside the `vscode` chart | Chart platform |
| Chart delivery | `prodbox charts list|status|deploy|delete` | Chart platform registry |
| Supported app delivery | Namespace-local `keycloak-postgres -> keycloak -> vscode` stack | Chart platform |
| Retained non-PV chart state | Repo-local `.prodbox-state/<namespace>/` | `prodbox charts` helpers plus the `rke2 delete --yes` preservation contract |
| AWS test resource lifecycle | `prodbox pulumi test-resources`, `prodbox pulumi test-destroy --yes` | Pulumi stack state plus the dedicated MinIO backend bucket |
| Validation | Named `prodbox test ...`, `prodbox pulumi test-resources`, `prodbox pulumi test-destroy --yes`, `prodbox tla-check`, `prodbox check-code` | Repository-owned commands |
| Stable doctrine | `documents/engineering/` | Governed docs |
| Status and blockers | `DEVELOPMENT_PLAN/` | This plan suite |

## Current Repository State

Completed and present in the repository:

- Repository-wide status, blocker, and cleanup tracking live in this plan suite.
- Runtime and CLI foundations exist: explicit Click command groups, command ADTs, eDAG builders, interpreter execution, named test suites, and documentation-topology guard coverage.
- The local host RKE2 lifecycle exists on `Ubuntu 24.04 LTS`, including `prodbox rke2 install`, `prodbox rke2 delete --yes`, reboot-time systemd enablement, and deterministic retained-state rebinding after full delete plus reinstall.
- The canonical AWS test-stack command surface now exists: `prodbox pulumi test-resources`, `prodbox pulumi test-destroy --yes`, local MinIO-backed Pulumi state in bucket `prodbox-test-pulumi-backends`, and automatic Pulumi test-stack destroy during `prodbox rke2 delete --yes`.
- The repository now includes the SSH-driven HA RKE2 bootstrap path for three Pulumi-managed `Ubuntu 24.04 LTS` EC2 instances in separate AZs via `src/prodbox/lib/aws_test_stack.py`, `src/prodbox/lib/ha_rke2_aws.py`, `src/prodbox/infra/aws_test_stack_program.py`, and `tests/integration/test_ha_rke2_aws.py`.
- Route 53 integration now uses fixture-owned hosted-zone lifecycle only, while Pulumi owns the multi-resource AWS test stack lifecycle; the tag-sweep and `aws_fixture_audit.py` cleanup model is no longer part of the supported architecture.
- The distributed gateway implementation exists with `prodbox gateway` management commands, TLA+ artifacts, unit coverage, and Kubernetes integration suites.
- `prodbox charts` exists as a first-class capability with deterministic retained PV naming and the namespace-local `keycloak-postgres -> keycloak -> vscode` stack.
- The intended public-edge stack in repository code is `MetalLB -> Traefik -> vscode` Ingress, with `vscode-nginx` acting only as the namespace-local auth proxy behind that edge.
- Pulumi subprocess handling injects the canonical nested-entrypoint override, and `Settings()` loads from `prodbox-config.json` (compiled from `prodbox-config.dhall`) via `Settings.from_config_json()` only.

Open, incomplete, or blocked:

- None.

The April 13, 2026 missing-config rerun and the April 14, 2026 AWS-backed rerun together close the intended end state: the local clean-room bootstrap path, the Pulumi-managed AWS lifecycle, the SSH-driven HA RKE2 proof, the aggregate `poetry run prodbox test all` closure, and the final remnant-free teardown all pass on the supported architecture.

## Current-Environment Validation Snapshot

- `poetry run prodbox check-code` passed on April 14, 2026 after the final closure updates.
- `poetry run prodbox test unit` passed on April 14, 2026 (`989 passed`).
- `poetry run prodbox rke2 delete --yes`, `rm -f prodbox-config.json`, `poetry run prodbox rke2 install`, `poetry run prodbox config show`, and `poetry run prodbox config validate` passed on April 13, 2026 from the missing compiled-config baseline; `config show` reported `storage.manual_pv_host_root=/home/matthewnowak/prodbox/.data`.
- `poetry run prodbox pulumi test-resources` passed on April 14, 2026 and created the canonical `aws-test` stack with three Pulumi-managed EC2 nodes in separate AZs.
- `poetry run prodbox pulumi test-destroy --yes` passed on April 14, 2026 and reported no AWS residue plus an empty backend bucket `prodbox-test-pulumi-backends`.
- `poetry run prodbox test all` passed on April 14, 2026 in `1h 20m 39s`; the aggregate rerun included the Pulumi lifecycle proof, the HA-over-SSH proof, and the lifecycle rebinding proof.
- The April 14, 2026 aggregate rerun restored the supported runtime and reached `CLASSIFICATION=ready-for-external-proof` during the public-edge diagnostic tail.
- `poetry run prodbox host public-edge` passed on April 13, 2026 with `CLASSIFICATION=ready-for-external-proof`, and `poetry run prodbox test integration public-dns` passed on April 13, 2026 (2 tests); the April 14 aggregate rerun re-proved the same public-edge state during runtime restore.
- A final `poetry run prodbox rke2 delete --yes` passed on April 14, 2026, preserved `/home/matthewnowak/prodbox/.data` and `/home/matthewnowak/prodbox/.prodbox-state`, left `rke2-server` inactive, and left `kubectl` unable to reach a cluster.

## Hard Constraints

- The only supported public CLI is `prodbox`.
- The only supported local operator environment is `Ubuntu 24.04 LTS` with systemd.
- The only supported AWS integration nodes are `Ubuntu 24.04 LTS` EC2 instances.
- `prodbox` owns the local RKE2 cluster lifecycle itself. The supported host path is explicit
  cluster install, service enablement for reboot recovery, inspection, and destructive cluster
  delete.
- AWS HA validation uses exactly three Pulumi-managed EC2 instances in separate availability zones.
- The supported remote-cluster deployment path is RKE2 in HA mode over SSH; EKS is not part of
  the supported architecture.
- The repository-root `prodbox-config.dhall` is the single configuration source.
  `prodbox config compile` remains the explicit compile surface, and canonical settings loads also
  auto-compile `prodbox-config.json` idempotently when the repository-root JSON artifact is
  missing or stale.
- `prodbox-config.dhall` must explicitly provide the manual PV host root. The canonical default is
  the repository `.data/` directory.
- The configured manual PV host root is reserved purely for PV content. Cluster secrets, gateway
  mesh keys, or other non-PV retained artifacts must not live there.
- Full local cluster delete preserves exactly two retained host roots: the configured manual PV
  host root for PV contents and the repo-local `.prodbox-state/` root for non-PV retained chart
  state.
- `prodbox rke2 delete --yes` wipes every other managed local-cluster remnant and must
  automatically destroy any Pulumi-managed AWS test stack before it removes the local cluster that
  hosts the MinIO backend.
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
- The Pulumi backend for AWS test stacks is the MinIO instance running on the local RKE2 cluster
  on the test host, using the dedicated bucket `prodbox-test-pulumi-backends`.
- The local cluster must be deployed before any remote AWS test stack is provisioned because it
  owns the Pulumi backend.
- Pulumi is the exclusive provisioner and deprovisioner for AWS test resources. No tag-based
  cleanup contract, pre-test AWS sweep, standalone janitor CLI, host cron job, or final
  `aws_fixture_audit.py` proof is part of the supported architecture.
- The named inspection and destroy surfaces for AWS test resources are
  `prodbox pulumi test-resources` and `prodbox pulumi test-destroy --yes`.
- No prodbox daemon or cron-driven background job runs on the host. The only supported
  steady-state long-running prodbox workload is inside the RKE2 cluster as a Kubernetes workload
  managed by `prodbox charts`.
- The only supported gateway startup path is `prodbox gateway start`, invoked as the entrypoint
  of the in-cluster gateway pod.
- The only supported Route 53 ownership and update path is gateway `dns_write_gate`.
- The only supported DNS model is explicit per-subdomain Route 53 records; wildcard public DNS is
  not part of the supported architecture.
- The only supported cluster-edge ingress controller is Traefik; namespace-local `vscode-nginx` is
  an application auth proxy behind it, not a competing edge controller.
- The only supported `vscode` delivery path is the cluster-backed `prodbox charts` stack.
- The only supported validation paths are named `prodbox` commands; raw passthrough or alternate
  operator workflows are debt to remove, not supported surfaces.
- Final clean-room handoff requires a single supported rerun path from
  `poetry run prodbox rke2 delete --yes` to `poetry run prodbox test all` with no manual RKE2,
  Pulumi, Helm, or host resolver repair steps in between; that path must include local-cluster
  rebuild, MinIO backend restore, remote HA stack create, SSH-driven RKE2 HA install, and final
  Pulumi destroy.
- Final clean-room handoff also requires that no Pulumi-managed Route 53, VPC, subnet,
  security-group, EC2, IAM, or backend-bucket residue remains.
- Authoritative public-host proof may not depend on `/etc/hosts` or other local resolver overrides
  for `vscode.resolvefintech.com`.
- Documents under `documents/` are stable doctrine and reference only. They do not own sprint
  histories, blocker tracking, or completion state.
- Compatibility shims, duplicate operator paths, mixed-purpose storage roots, EKS-specific AWS
  validation, and tag-based AWS cleanup helpers are removal targets, not long-term architecture.

## Related Documents

- [README.md](README.md)
- [system-components.md](system-components.md)
- [phase-0-planning-documentation.md](phase-0-planning-documentation.md)
- [phase-4-lifecycle-canonical-paths.md](phase-4-lifecycle-canonical-paths.md)
- [phase-5-public-host-validation.md](phase-5-public-host-validation.md)
- [phase-6-clean-room-handoff.md](phase-6-clean-room-handoff.md)
- [../documents/engineering/README.md](../documents/engineering/README.md)
