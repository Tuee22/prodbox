# File: DEVELOPMENT_PLAN/00-overview.md
# prodbox Development Plan - Overview

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [system-components.md](system-components.md), [phase-0-planning-documentation.md](phase-0-planning-documentation.md), [phase-1-runtime-cli-aws-foundations.md](phase-1-runtime-cli-aws-foundations.md), [phase-2-gateway-dns.md](phase-2-gateway-dns.md), [phase-3-chart-platform-vscode.md](phase-3-chart-platform-vscode.md), [phase-4-lifecycle-canonical-paths.md](phase-4-lifecycle-canonical-paths.md), [phase-5-public-host-validation.md](phase-5-public-host-validation.md), [phase-6-clean-room-handoff.md](phase-6-clean-room-handoff.md), [phase-7-aws-iam-quota-automation.md](phase-7-aws-iam-quota-automation.md)

> **Purpose**: Provide the architectural overview, clean-room sequence, repository state, and hard
> constraints for the prodbox development plan.


## Vision

Build a clean-room prodbox repository with:

1. One explicit `prodbox` CLI surface.
2. One supported local operator environment: `Ubuntu 24.04 LTS` with systemd.
3. One host-owned `prodbox rke2 install|delete --yes|status|start|stop|restart|logs` surface for
   the local RKE2 cluster that runs on the test host.
4. Two AWS-backed cluster deployment and validation patterns under `prodbox`: one EKS-backed path
   and one SSH-driven HA RKE2 path. The HA RKE2 path targets exactly three Pulumi-managed
   `Ubuntu 24.04 LTS` EC2 instances in separate availability zones.
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
16. One `prodbox config setup` interactive onboarding wizard that populates all
    `prodbox-config.dhall` fields from live AWS queries and user input, including AWS account
    creation guidance with Free Tier options, region and Route 53 zone selection, ACME provider
    guidance (ZeroSSL with EAB or Let's Encrypt), and dedicated IAM user creation with a single
    consolidated inline policy. One `prodbox aws` surface for standalone IAM user lifecycle
    management, inline policy generation, and service quota inspection and requests. All IAM and
    quota operations use the AWS CLI tool via subprocess with ephemeral admin credentials that are
    never persisted. A dedicated `aws_admin` Dhall config section holds test-only elevated
    credentials ignored by all non-test commands; normal `aws.*` operational credentials are
    populated exclusively through the interactive flows.

## Clean-Room Sequence

| Phase | Focus | Closure Result |
|-------|-------|----------------|
| 0 | Planning and Documentation Topology | The plan becomes the single roadmap and status source |
| 1 | Runtime, CLI, and AWS Validation Foundations | Core CLI, the Ubuntu 24.04 support gate, host-owned local RKE2 install/delete, the local-cluster-first MinIO backend, and both intended AWS-backed validation paths (EKS-backed and three-node HA-over-SSH) are established |
| 2 | Distributed Gateway Runtime and DNS Ownership | The distributed gateway, TLA+ entrypoint, and Route 53 write capability exist |
| 3 | Chart Platform and Cluster-Backed `vscode` Delivery | Deterministic retained storage and the namespace-local stack are canonical |
| 4 | Lifecycle Hardening and Canonical-Path Cleanup | Cluster delete/install lifecycle, PV-root doctrine, Pulumi-owned AWS test teardown, and canonical cleanup ownership are established |
| 5 | Public Hostname Closure and Authoritative External Proof | Public DNS, TLS, ingress, and Keycloak redirect proof are canonicalized |
| 6 | Final Clean-Room Rerun and Zero-Legacy Handoff | The full rerun passes from local cluster delete plus missing compiled config through local backend restore, both AWS-backed validation patterns, final Pulumi destroy, and an empty legacy backlog |
| 7 | Interactive Onboarding, AWS IAM, and Quota Automation | The interactive onboarding wizard, standalone IAM lifecycle, quota management, and test-only elevated credential harness are established |

Phase status in this plan is scoped to the surface owned by that phase. Later phase-owned work can
remain closed when an earlier phase reopens, but the reopened dependency and the unfinished global
handoff criteria must be called out explicitly in this overview and in
[README.md](README.md).

## Architecture Summary

| Surface | Canonical Path | Authority |
|---------|----------------|-----------|
| CLI control plane | `poetry run prodbox <command>` | Repository worktree |
| Supported host runtime | `Ubuntu 24.04 LTS` with systemd | `prodbox` supported-host gate |
| AWS auth/config | Repository-root `prodbox-config.dhall`, auto-compiled idempotently to `prodbox-config.json` by canonical settings loads and read by `Settings()` | Repository root |
| Local RKE2 lifecycle | `prodbox rke2 install`, `status`, `delete --yes` | `prodbox` CLI for host-owned local cluster lifecycle, service enablement, and full delete that preserves only the configured PV root plus the repo-local `.prodbox-state/` retained chart-state root |
| AWS-backed EKS validation | `prodbox pulumi eks-resources`, `prodbox pulumi eks-destroy --yes`, `poetry run prodbox test integration aws-eks` | Intended companion AWS deployment pattern now implemented alongside the HA RKE2 path |
| AWS-backed HA RKE2 validation | `prodbox pulumi test-resources` plus SSH-driven `prodbox` RKE2 bootstrap | Pulumi provisions three EC2 instances in separate AZs; `prodbox` orchestrates remote HA install over SSH |
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
| AWS test resource lifecycle | `prodbox pulumi eks-resources`, `prodbox pulumi eks-destroy --yes`, `prodbox pulumi test-resources`, `prodbox pulumi test-destroy --yes` | Pulumi stack state plus the dedicated MinIO backend bucket |
| Validation | Named `prodbox test ...`, `prodbox pulumi eks-resources`, `prodbox pulumi eks-destroy --yes`, `prodbox pulumi test-resources`, `prodbox pulumi test-destroy --yes`, `prodbox tla-check`, `prodbox check-code` | Repository-owned commands |
| Stable doctrine | `documents/engineering/` | Governed docs |
| Interactive onboarding | `prodbox config setup` | Interactive wizard populating all `prodbox-config.dhall` fields from live AWS queries, ACME guidance, and user input via ephemeral admin credentials |
| AWS IAM lifecycle | `prodbox aws setup`, `prodbox aws teardown` | `prodbox` CLI via ephemeral admin credentials and AWS CLI subprocess |
| AWS quota management | `prodbox aws check-quotas`, `prodbox aws request-quotas` | `prodbox` CLI via ephemeral admin credentials and AWS CLI subprocess |
| AWS IAM policy reference | `prodbox aws policy [--tier core\|full]` | Pure computation (no credentials) |
| Test-only elevated credentials | `prodbox-config.dhall` `aws_admin` section | Ignored by all non-test commands |
| Status and blockers | `DEVELOPMENT_PLAN/` | This plan suite |

## Current Repository State

Completed and present in the repository:

- Repository-wide status, blocker, and cleanup tracking live in this plan suite.
- Runtime and CLI foundations exist: explicit Click command groups, command ADTs, eDAG builders, interpreter execution, named test suites, and documentation-topology guard coverage.
- The local host RKE2 lifecycle exists on `Ubuntu 24.04 LTS`, including `prodbox rke2 install`, `prodbox rke2 delete --yes`, reboot-time systemd enablement, and deterministic retained-state rebinding after full delete plus reinstall.
- The implemented AWS test-stack command surface now exists for the HA RKE2 branch: `prodbox pulumi test-resources`, `prodbox pulumi test-destroy --yes`, local MinIO-backed Pulumi state in bucket `prodbox-test-pulumi-backends`, and automatic Pulumi test-stack destroy during `prodbox rke2 delete --yes`.
- The repository now includes the SSH-driven HA RKE2 bootstrap path for three Pulumi-managed `Ubuntu 24.04 LTS` EC2 instances in separate AZs via `src/prodbox/lib/aws_test_stack.py`, `src/prodbox/lib/ha_rke2_aws.py`, `src/prodbox/infra/aws_test_stack_program.py`, and `tests/integration/test_ha_rke2_aws.py`.
- Route 53 integration now uses fixture-owned hosted-zone lifecycle only, while Pulumi owns the multi-resource AWS test stack lifecycle; the tag-sweep and standalone janitor cleanup model are no longer part of the supported architecture.
- The distributed gateway implementation exists with `prodbox gateway` management commands, TLA+ artifacts, unit coverage, and Kubernetes integration suites.
- `prodbox charts` exists as a first-class capability with deterministic retained PV naming and the namespace-local `keycloak-postgres -> keycloak -> vscode` stack.
- The intended public-edge stack in repository code is `MetalLB -> Traefik -> vscode` Ingress, with `vscode-nginx` acting only as the namespace-local auth proxy behind that edge.
- Pulumi subprocess handling injects the canonical nested-entrypoint override, and `Settings()` loads from `prodbox-config.json` (compiled from `prodbox-config.dhall`) via `Settings.from_config_json()` only.
- Phase 7 implementation is present: `prodbox config setup`, `prodbox aws policy|setup|teardown|check-quotas|request-quotas`, the `aws_admin` Dhall/settings harness, the new onboarding/AWS engineering docs, and the dedicated `aws-iam` integration suite.
- Aggregate supported-runtime repair now uses the canonical `home` stack semantics even when the
  local backend has no active selection: it idempotently selects or creates `home` before raw
  Pulumi AWS/provider repair runs, so `poetry run prodbox test all` does not depend on a manual
  `pulumi stack select`.

Open, incomplete, or blocked:

None.

The April 13, 2026 missing-config rerun, the April 14, 2026 HA AWS reruns, and the April 15,
2026 destructive rerun from `poetry run prodbox rke2 delete --yes`,
`docker system prune -af --volumes`, `sudo rm -rf .data`, and `poetry run prodbox test all` now
close phases 0-7 on their owned surfaces. The repository exposes both intended AWS-backed
validation branches through named `prodbox` create/validate/destroy surfaces, the zero-legacy
ledger is empty in `Pending Removal`, and Phase 7 is fully validated in the worktree including
the dedicated `aws_admin.*` harness, raw-config recovery when operational `aws.*` credentials are
blank, and the supported-runtime repair that refreshes stale Pulumi AWS provider state after
idempotently selecting or creating the canonical `home` stack before EC2-backed validation. The
repository is back at the zero-legacy architecture state on paper and in code.

## Current-Environment Validation Snapshot

- `poetry run prodbox check-code` passed on April 15, 2026 after the final
  status-documentation refresh.
- `poetry run prodbox test unit` passed on April 15, 2026 (`1078 passed`).
- `poetry run prodbox test integration aws-iam` passed on April 14, 2026 (`2 passed`).
- `poetry run prodbox test integration lifecycle` passed on April 15, 2026 (`2 passed` in `16m 06s`), proving Harbor-backed lifecycle reinstall and PVC/PV rebinding after the fully pruned Docker baseline.
- `poetry run prodbox rke2 delete --yes`, `rm -f prodbox-config.json`, `poetry run prodbox rke2 install`, `poetry run prodbox config show`, and `poetry run prodbox config validate` passed on April 13, 2026 from the missing compiled-config baseline; `config show` reported `storage.manual_pv_host_root=/home/matthewnowak/prodbox/.data`.
- `poetry run prodbox pulumi eks-resources`, `poetry run prodbox test integration aws-eks`, and
  `poetry run prodbox pulumi eks-destroy --yes` passed on April 15, 2026; the named EKS suite
  `tests/integration/test_aws_eks.py` passed (`1 passed` in `22m 03s`).
- `poetry run prodbox pulumi test-resources` passed on April 14, 2026 and created the canonical `aws-test` stack with three Pulumi-managed EC2 nodes in separate AZs.
- `poetry run prodbox pulumi test-destroy --yes` passed on April 14, 2026 and again inside the April 15, 2026 aggregate postflight tail, each time reporting no AWS residue plus an empty backend bucket `prodbox-test-pulumi-backends`.
- `poetry run prodbox rke2 delete --yes`, `docker system prune -af --volumes`, `sudo rm -rf .data`,
  and `poetry run prodbox test all` passed on April 15, 2026 from a local file-backed Pulumi
  backend with no active stack selection; the aggregate rerun finished in `1h 42m 48s`, selected
  or created the canonical `home` stack during supported-runtime repair, included the public-DNS
  proof, the EKS-backed proof, the Pulumi lifecycle proof, the HA-over-SSH proof, the gateway and
  chart suites, the lifecycle rebinding proof, and the real IAM lifecycle proof, restored the supported runtime to
  `CLASSIFICATION=ready-for-external-proof`, and auto-destroyed both `aws-eks-test` and
  `aws-test` with an empty backend bucket.
- `poetry run prodbox host public-edge` passed on April 13, 2026 with `CLASSIFICATION=ready-for-external-proof`, and `poetry run prodbox test integration public-dns` passed on April 13, 2026 (2 tests); the April 14 aggregate rerun re-proved the same public-edge state during runtime restore.
- A final `poetry run prodbox rke2 delete --yes` passed on April 14, 2026, preserved `/home/matthewnowak/prodbox/.data` and `/home/matthewnowak/prodbox/.prodbox-state`, left `rke2-server` inactive, and left `kubectl` unable to reach a cluster.

## Hard Constraints

- The only supported public CLI is `prodbox`.
- The only supported local operator environment is `Ubuntu 24.04 LTS` with systemd.
- The HA RKE2 AWS integration nodes are `Ubuntu 24.04 LTS` EC2 instances in separate
  availability zones.
- `prodbox` owns the local RKE2 cluster lifecycle itself. The supported host path is explicit
  cluster install, service enablement for reboot recovery, inspection, and destructive cluster
  delete.
- AWS HA validation uses exactly three Pulumi-managed EC2 instances in separate availability zones.
- The intended AWS-backed cluster deployment patterns under `prodbox` are both EKS and RKE2 in HA
  mode over SSH. Both are now implemented and validated from the supported destructive baseline.
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
  automatically destroy both Pulumi-managed AWS test stacks before it removes the local cluster
  that hosts the MinIO backend.
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
- Aggregate supported-runtime repair must idempotently select or create the canonical Pulumi
  `home` stack when backend state is blank or unselected; no supported rerun requires a manual
  `pulumi stack select`.
- Pulumi is the exclusive provisioner and deprovisioner for AWS test resources. No tag-based
  cleanup contract, pre-test AWS sweep, standalone janitor CLI, host cron job, or standalone
  final AWS audit helper is part of the supported architecture.
- The named inspection and destroy surfaces for AWS test resources are
  `prodbox pulumi eks-resources`, `prodbox pulumi eks-destroy --yes`,
  `prodbox pulumi test-resources`, and `prodbox pulumi test-destroy --yes`.
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
  rebuild, MinIO backend restore, the EKS-backed validation path, the HA RKE2-over-SSH validation
  path, and final Pulumi destroy.
- Final clean-room handoff also requires that no Pulumi-managed Route 53, VPC, subnet,
  security-group, EC2, IAM, EKS, or backend-bucket residue remains.
- Authoritative public-host proof may not depend on `/etc/hosts` or other local resolver overrides
  for `vscode.resolvefintech.com`.
- Documents under `documents/` are stable doctrine and reference only. They do not own sprint
  histories, blocker tracking, or completion state.
- Compatibility shims, duplicate operator paths, mixed-purpose storage roots, obsolete janitor-era
  AWS cleanup helpers, and tag-based AWS cleanup helpers are removal targets, not long-term
  architecture.
- `prodbox aws` commands use the AWS CLI tool via subprocess with explicit env-var credentials; no
  boto3, no Pulumi for IAM or quota operations, no host `~/.aws/` modification.
- Ephemeral admin credentials are prompted interactively for production use and never persisted to
  disk or host AWS configuration. The `aws_admin` Dhall config section exists only for test-suite
  use.
- Normal `aws.*` operational credentials in `prodbox-config.dhall` are populated exclusively
  through the interactive `prodbox config setup` or `prodbox aws setup` flows; manual credential
  editing is not the supported onboarding path.
- `aws_admin.*` credentials are ignored by all prodbox commands outside the `prodbox aws` command
  group and the test suite.

## Related Documents

- [README.md](README.md)
- [system-components.md](system-components.md)
- [phase-0-planning-documentation.md](phase-0-planning-documentation.md)
- [phase-4-lifecycle-canonical-paths.md](phase-4-lifecycle-canonical-paths.md)
- [phase-5-public-host-validation.md](phase-5-public-host-validation.md)
- [phase-6-clean-room-handoff.md](phase-6-clean-room-handoff.md)
- [phase-7-aws-iam-quota-automation.md](phase-7-aws-iam-quota-automation.md)
- [../documents/engineering/README.md](../documents/engineering/README.md)
