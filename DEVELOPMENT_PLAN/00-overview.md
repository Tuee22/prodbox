# prodbox Development Plan - Overview

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [system-components.md](system-components.md), [phase-0-planning-documentation.md](phase-0-planning-documentation.md), [phase-1-runtime-cli-aws-foundations.md](phase-1-runtime-cli-aws-foundations.md), [phase-2-gateway-dns.md](phase-2-gateway-dns.md), [phase-3-chart-platform-vscode.md](phase-3-chart-platform-vscode.md), [phase-4-lifecycle-canonical-paths.md](phase-4-lifecycle-canonical-paths.md), [phase-5-public-host-validation.md](phase-5-public-host-validation.md), [phase-6-clean-room-handoff.md](phase-6-clean-room-handoff.md), [phase-7-aws-iam-quota-automation.md](phase-7-aws-iam-quota-automation.md)

> **Purpose**: Provide the target architecture, current baseline, clean-room sequence, and hard
> constraints for the Haskell rewrite of `prodbox`.

## Vision

Build a clean-room Haskell `prodbox` repository with:

1. One explicit `prodbox` CLI surface implemented in Haskell.
2. One supported local operator environment: `Ubuntu 24.04 LTS` with systemd.
3. One host-owned `prodbox rke2 install|delete --yes|status|start|stop|restart|logs` surface for
   the local RKE2 cluster.
4. Two AWS-backed cluster deployment and validation patterns under `prodbox`: one EKS-backed path
   and one SSH-driven HA RKE2 path on exactly three Pulumi-managed `Ubuntu 24.04 LTS` EC2
   instances in separate availability zones.
5. One repository-root `prodbox-config.dhall` as the single configuration source.
6. One host build root `.build/`, explicitly configured in `cabal.project`, containing the local
   Haskell build artifacts including the `prodbox` binary.
7. One container build root `/opt/build`, explicitly configured by the Dockerfile for containerized
   Haskell builds.
8. One local-cluster-first Pulumi backend model: the local RKE2 cluster runs MinIO and stores AWS
   test-stack state in the dedicated bucket `prodbox-test-pulumi-backends`.
9. One distributed gateway runtime implemented in Haskell and deployed as an in-cluster Kubernetes
   workload with leader election and Route 53 write ownership.
10. One retained PV host-path model rooted at the configured manual PV root, defaulting to
    `.data/<namespace>/<release>/<workload>/<ordinal>/<claim>`.
11. One retained non-PV chart-state root under `.prodbox-state/<namespace>/`.
12. One supported cluster-backed `vscode` delivery path.
13. One named validation command per major surface.
14. One explicit ledger for every Python-removal, compatibility, or cleanup item still slated for
    deletion.
15. Pulumi retained as the infrastructure engine, but with no supported Python Pulumi program.

## Clean-Room Sequence

| Phase | Focus | Closure Result |
|-------|-------|----------------|
| 0 | Planning and Documentation Topology for Haskell Rewrite | The plan suite is reopened and rewritten around the Haskell end state |
| 1 | Haskell Runtime, CLI, Config, and Pulumi Foundations | One supported Haskell binary owns CLI, config, lifecycle, and AWS validation foundations |
| 2 | Haskell Gateway Runtime and DNS Ownership | Gateway runtime, formal verification entrypoint, and Route 53 ownership move to Haskell |
| 3 | Haskell Chart Platform and Cluster-Backed `vscode` Delivery | Chart orchestration, retained storage, and `vscode` delivery move to Haskell |
| 4 | Lifecycle Hardening, Pulumi Decoupling, and Python Removal | Lifecycle parity closes, Pulumi is Python-free, and Python residue is actively removed |
| 5 | Public Hostname Closure and External Proof on the Haskell Stack | Public DNS, TLS, ingress, and external proof rerun through Haskell-only command paths |
| 6 | Final Clean-Room Rerun and Zero-Python Handoff | The destructive rerun passes with no supported Python dependency and an empty removal ledger |
| 7 | Interactive Onboarding, AWS IAM, and Quota Automation in Haskell | Interactive configuration and AWS administration close on Haskell-only paths |

## Architecture Summary

| Surface | Canonical Target Path | Authority |
|---------|-----------------------|-----------|
| CLI control plane | `prodbox <command>` | Haskell executable |
| Host build artifacts | `.build/` | `cabal.project` |
| Container build artifacts | `/opt/build` | Dockerfile |
| Supported host runtime | `Ubuntu 24.04 LTS` with systemd | `prodbox` supported-host gate |
| Configuration | Repository-root `prodbox-config.dhall` plus materialized `prodbox-config.json` when required | Repository root |
| Local RKE2 lifecycle | `prodbox rke2 install|delete --yes|status|start|stop|restart|logs` | Haskell CLI |
| AWS-backed EKS validation | `prodbox pulumi eks-resources|eks-destroy --yes` plus `prodbox test integration aws-eks` | Haskell orchestration plus Pulumi |
| AWS-backed HA RKE2 validation | `prodbox pulumi test-resources|test-destroy --yes` plus `prodbox test integration ha-rke2-aws` | Haskell orchestration plus Pulumi |
| Pulumi backend state | MinIO bucket `prodbox-test-pulumi-backends` on the local cluster | Local cluster bootstrap |
| Gateway startup | `prodbox gateway start` | Haskell gateway binary in the gateway container |
| Gateway DNS writes | `dns_write_gate` | In-cluster elected Haskell gateway leader |
| Chart delivery | `prodbox charts list|status|deploy|delete` | Haskell chart platform |
| Public-edge diagnostics | `prodbox host public-edge` | Haskell CLI |
| Interactive onboarding | `prodbox config setup` | Haskell CLI plus AWS CLI subprocesses |
| AWS IAM and quota management | `prodbox aws policy|setup|teardown|check-quotas|request-quotas` | Haskell CLI plus AWS CLI subprocesses |
| Formal verification | `prodbox tla-check` | Haskell CLI invoking the TLA+ toolchain |
| Status and blockers | `DEVELOPMENT_PLAN/` | This plan suite |

## Current Repository State

The repository state on April 16, 2026 is intentionally split between baseline and target:

### Baseline Present in the Worktree

- The implementation is still Python under `src/prodbox/` and `tests/`.
- The previously closed Python clean-room architecture was validated through April 15, 2026.
- Poetry, pytest, mypy, ruff, Python type stubs, and Python Pulumi programs are still present in
  the repository.

### Open Against the Haskell Target

- No Haskell `prodbox` binary exists yet.
- No `cabal.project`-owned `.build/` host artifact path exists yet.
- No Dockerfile-enforced `/opt/build` container build path exists yet.
- No gateway, chart, lifecycle, Pulumi, or AWS administration surface has been reimplemented in
  Haskell.
- The Python codebase has not been removed and remains tracked in
  [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md).

### Interpretation

The April 15, 2026 Python clean-room rerun remains useful as migration-source proof, but it does
not close any implementation phase in this reopened Haskell plan.

## Hard Constraints

- The only supported public CLI is `prodbox`.
- The only supported host runtime is `Ubuntu 24.04 LTS` with systemd.
- The host build root is `.build/`, configured explicitly in `cabal.project`.
- The container build root is `/opt/build`, configured explicitly in the Dockerfile.
- `dist-newstyle/` is not a supported artifact contract for operators or docs.
- The repository-root `prodbox-config.dhall` is the single configuration source unless a later plan
  revision changes that rule explicitly.
- The configured manual PV host root defaults to `.data/` and is reserved for PV contents only.
- Full cluster delete preserves exactly two retained host roots: the configured manual PV root and
  the repo-local `.prodbox-state/` root.
- The local cluster must exist before any remote AWS test stack is provisioned because it owns the
  Pulumi backend.
- Pulumi remains the exclusive provisioner and destroyer for AWS test resources.
- No supported Pulumi program or orchestration path may depend on Python.
- The only supported gateway steady state is inside the cluster as a Kubernetes workload.
- The only supported DNS model is explicit per-subdomain Route 53 records; wildcard public DNS is
  not part of the supported architecture.
- The only supported cluster-edge ingress controller is Traefik.
- The only supported `vscode` delivery path is the cluster-backed `prodbox charts` stack.
- Final handoff requires a destructive rerun from full local delete through final AWS teardown on
  the Haskell stack with no Python implementation dependency.
- Final handoff also requires that no supported-path Python source, Python packaging metadata,
  Python test harness, Python Pulumi program, or Python type-stub inventory remains in the
  repository.
