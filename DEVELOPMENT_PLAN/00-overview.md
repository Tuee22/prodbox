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
5. One repository-root `prodbox-config.dhall` as the single configuration source, decoded
   directly into Haskell types with `prodbox-config-types.dhall` as the shared schema and no
   generated JSON artifact on the supported path.
6. One host build root `.build/` with the operator-facing binary at `.build/prodbox`, produced by
   the canonical `cabal build --builddir=.build exe:prodbox` invocation followed by a copy step
   that places the binary at the root of `.build/`. The operator runs `./.build/prodbox`.
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
| 0 | Planning and Documentation Topology for Haskell Rewrite | The plan suite is rewritten around the Haskell end state |
| 1 | Haskell Runtime, CLI, Config, and Pulumi Foundations | One supported Haskell binary owns CLI, config, lifecycle, test, and AWS validation foundations |
| 2 | Haskell Gateway Runtime and DNS Ownership | Gateway runtime, formal verification entrypoint, and Route 53 ownership move to Haskell |
| 3 | Haskell Chart Platform and Cluster-Backed `vscode` Delivery | Chart orchestration, retained storage, and `vscode` delivery move to Haskell |
| 4 | Lifecycle Hardening, Pulumi Decoupling, and Python Removal | Lifecycle parity closes, Pulumi is Python-free, and Python residue is removed |
| 5 | Public Hostname Closure and External Proof on the Haskell Stack | Public DNS, TLS, ingress, and external proof rerun through Haskell-only command paths |
| 6 | Final Clean-Room Rerun and Zero-Python Handoff | The destructive rerun passes with no supported Python dependency and an empty removal ledger |
| 7 | Interactive Onboarding, AWS IAM, and Quota Automation in Haskell | Interactive configuration and AWS administration close on Haskell-only paths |

## Architecture Summary

| Surface | Canonical Target Path | Authority |
|---------|-----------------------|-----------|
| CLI control plane | `prodbox <command>` | Haskell executable |
| Host build artifacts | `.build/prodbox` | `cabal build --builddir=.build exe:prodbox` plus copy to `.build/prodbox` |
| Container build artifacts | `/opt/build` | Dockerfile |
| Supported host runtime | `Ubuntu 24.04 LTS` with systemd | `prodbox` supported-host gate |
| Configuration | Repository-root `prodbox-config.dhall` decoded directly into Haskell types, with `prodbox-config-types.dhall` as the shared schema and no supported `prodbox-config.json` artifact | Repository root |
| Host diagnostics | `prodbox host ensure-tools|info|check-ports|firewall|public-edge` | Haskell CLI |
| Local RKE2 lifecycle | `prodbox rke2 install|delete --yes|status|start|stop|restart|logs` | Haskell CLI |
| Kubernetes utilities | `prodbox k8s health|wait|logs` | Haskell CLI |
| Pulumi home stack lifecycle | `prodbox pulumi up|destroy|preview|refresh|stack-init` | Haskell orchestration plus Pulumi |
| AWS-backed EKS validation | `prodbox pulumi eks-resources|eks-destroy --yes` plus `prodbox test integration aws-eks` | Haskell orchestration plus Pulumi |
| AWS-backed HA RKE2 validation | `prodbox pulumi test-resources|test-destroy --yes` plus `prodbox test integration ha-rke2-aws` | Haskell orchestration plus Pulumi |
| Pulumi backend state | MinIO bucket `prodbox-test-pulumi-backends` on the local cluster | Local cluster bootstrap |
| Gateway startup | `prodbox gateway start` | Haskell gateway runtime |
| Gateway DNS writes | `dns_write_gate` | In-cluster elected Haskell gateway leader |
| DNS check | `prodbox dns check` | Haskell CLI |
| Chart delivery | `prodbox charts list|status|deploy|delete` | Haskell chart platform |
| Public-edge diagnostics | `prodbox host public-edge` | Haskell CLI |
| Interactive onboarding | `prodbox config setup` | Haskell CLI plus AWS CLI subprocesses |
| AWS IAM and quota management | `prodbox aws policy|setup|teardown|check-quotas|request-quotas` | Haskell CLI plus AWS CLI subprocesses |
| Formal verification | `prodbox tla-check` | Haskell CLI invoking the TLA+ toolchain |
| Status and blockers | `DEVELOPMENT_PLAN/` | This plan suite |

## Current Repository State

The repository state as of April 18, 2026 is a Haskell-only codebase with all phases closed again:

### Haskell-Only Worktree

- The compiled Haskell `prodbox` binary exists under `app/`, `src/Prodbox/`, `test/`,
  `prodbox.cabal`, `cabal.project`, and `Dockerfile`.
- All Python source (`src/prodbox/`, `tests/`, `typings/`), Python packaging (`pyproject.toml`,
  `poetry.toml`, `.python-version`), and Python bridge modules (`Backend/Python.hs`,
  `PythonEnv.hs`) have been deleted from the repository.
- Repository-root config artifacts are `prodbox-config.dhall` and `prodbox-config-types.dhall`;
  `src/Prodbox/Settings.hs` owns Dhall decoding, masked display, and validation with no supported
  JSON materialization path. `src/Prodbox/Aws.hs` owns `config setup` plus
  `aws policy|setup|teardown|check-quotas|request-quotas`.
- All Pulumi programs are YAML-based: `pulumi/home/Main.yaml`, `pulumi/aws-eks/Main.yaml`, and
  `pulumi/aws-test/Main.yaml`. The root `Pulumi.yaml` uses `runtime: yaml`.
- The gateway Dockerfile (`docker/gateway.Dockerfile`) builds a Haskell binary using a multi-stage
  build with `haskell:9.6.7` builder and `debian:bookworm-slim` runtime.
- `CheckCode.hs` runs `cabal build --builddir=.build all` without any Python tooling and syncs the
  operator-facing host binary to `.build/prodbox` after a successful build.
- `TestRunner.hs` runs Haskell test suites via `cabal test`, the native `cli` and `env` suites via
  `test/integration/cli/Main.hs` and `test/integration/env/Main.hs`, and the named real-world
  integration proofs via `src/Prodbox/TestValidation.hs`.
- `cabal build --builddir=.build exe:prodbox` and the native `cli` and `env` integration suites
  pass on the April 18, 2026 worktree.
- The root Dockerfile builds the Haskell binary under `/opt/build`.
- `cabal.project` stays minimal; the `.build/` contract is enforced by the canonical
  `--builddir=.build` command-line flag. After building, the binary is copied to `.build/prodbox`
  so operators run `./.build/prodbox` directly.
- The supported Haskell command matrix is `config setup|show|validate`,
  `aws policy|setup|teardown|check-quotas|request-quotas`,
  `host ensure-tools|check-ports|info|firewall|public-edge`, `rke2`, `pulumi`, `dns check`,
  `gateway start|status|config-gen`, `charts`, `k8s health|wait|logs`, `check-code`, `test`, and
  `tla-check`.
- Root guidance docs and the governed docs listed in Sprint `1.2` are aligned with the
  Haskell-only repository and current validation harness.

### Interpretation

The repository remains Haskell-only. No Python source, Python toolchain, Python Pulumi programs,
or Python bridge modules remain in the repository. The reopened Phase `1` closure is complete: the
native validation harness owns every named proof surface behind `prodbox test ...`, the supported
config contract is direct `Dhall -> Haskell types`, and the governed docs are aligned with the
current repository state.

## Haskell-Only Architecture by Surface

| Surface | Implementation | Completed In |
|---------|----------------|--------------|
| CLI frontend and command surface | `app/prodbox/Main.hs`, `src/Prodbox/CLI/Parser.hs`, `src/Prodbox/Native.hs` | Phase 1 |
| Configuration and settings | `src/Prodbox/Settings.hs`, `prodbox-config.dhall`, `prodbox-config-types.dhall` | Phase 1 |
| Host and Kubernetes helpers | `src/Prodbox/Host.hs`, `src/Prodbox/K8s.hs` | Phase 1 |
| Local lifecycle and registry pipeline | `src/Prodbox/CLI/Rke2.hs` | Phase 1 |
| Pulumi orchestration and YAML stack programs | `src/Prodbox/CLI/Pulumi.hs`, `src/Prodbox/Infra/`, `pulumi/home/Main.yaml`, `pulumi/aws-eks/Main.yaml`, `pulumi/aws-test/Main.yaml` | Phase 4 |
| DNS inspection | `src/Prodbox/Dns.hs` | Phase 2 |
| Gateway runtime and packaging | `src/Prodbox/Gateway.hs`, `src/Prodbox/Gateway/Daemon.hs`, `src/Prodbox/Gateway/Types.hs`, `docker/gateway.Dockerfile` | Phase 2 |
| Formal verification | `src/Prodbox/Tla.hs`, `documents/engineering/tla/` | Phase 2 |
| Chart platform and retained state | `src/Prodbox/CLI/Charts.hs`, `src/Prodbox/Lib/ChartPlatform.hs`, `src/Prodbox/Lib/Storage.hs`, `charts/`, `.prodbox-state/` | Phase 3 |
| Public-edge diagnostics | `src/Prodbox/Host.hs` | Phase 5 |
| Onboarding and AWS administration | `src/Prodbox/Aws.hs` | Phase 7 |
| Test harness and quality gate | `src/Prodbox/CheckCode.hs`, `src/Prodbox/TestRunner.hs`, `src/Prodbox/TestValidation.hs`, `src/Prodbox/Effect.hs`, `src/Prodbox/EffectDAG.hs`, `src/Prodbox/EffectInterpreter.hs`, `src/Prodbox/Prerequisite.hs`, `src/Prodbox/Result.hs`, `src/Prodbox/Subprocess.hs`, `src/Prodbox/SupportedRuntime.hs`, `src/Prodbox/TestPlan.hs`, `test/` | Phase 1, Phase 4 |

## Current Execution State

All phases are closed:

- Phase 0 remains done. The plan-suite rewrite around the Haskell end state still stands.
- Phase 1 is done. Sprint `1.1` owns the Haskell binary and build topology, Sprint `1.2` owns the
  direct-Dhall config contract plus native validation harness and doc harmony, and Sprint `1.3`
  remains done on lifecycle and AWS validation foundations.
- Phase 2 remains done. The gateway daemon runtime runs natively in Haskell, the gateway Dockerfile
  builds a Haskell binary, and TLA+ parity is preserved on the owned runtime surfaces.
- Phase 3 remains done. Chart runtime and `vscode` delivery run through native Haskell modules.
- Phase 4 remains done. Lifecycle parity is Haskell-only, all Pulumi programs are YAML, and all
  Python source and toolchain artifacts remain removed from the repository.
- Phase 5 remains done. Public hostname diagnostics and external proof are owned by the Haskell
  stack.
- Phase 6 remains done. The destructive rerun and zero-Python handoff criteria remain closed.
- Phase 7 remains done. Interactive onboarding, IAM automation, and quota management all remain
  Haskell-owned, and the real IAM proof now runs through the native validation harness.

## Hard Constraints

- The only supported public CLI is `prodbox`.
- The rewrite preserves the full supported command matrix in
  [../documents/engineering/cli_command_surface.md](../documents/engineering/cli_command_surface.md)
  unless a later plan revision changes it explicitly.
- The only supported host runtime is `Ubuntu 24.04 LTS` with systemd.
- The host build root is `.build/` with the operator-facing binary at `.build/prodbox`, enforced
  by the canonical `cabal build --builddir=.build exe:prodbox` invocation plus a copy step. The
  operator runs `./.build/prodbox`.
- The container build root is `/opt/build`, configured explicitly in the Dockerfile.
- `dist-newstyle/` is not a supported artifact contract for operators or docs.
- The repository-root `prodbox-config.dhall` is the single configuration source unless a later plan
  revision changes that rule explicitly.
- The supported configuration handoff is direct `Dhall -> Haskell types`; no supported command or
  validation path may create `prodbox-config.json`, and `prodbox config compile` is not part of
  the target command surface.
- The configured manual PV host root defaults to `.data/` and is reserved for PV contents only.
- Full cluster delete preserves exactly two retained host roots: the configured manual PV root and
  the repo-local `.prodbox-state/` root.
- The current supported lifecycle includes the Harbor local-registry and Docker Hub mirror
  pipeline; removing or shrinking that scope requires an explicit later plan change.
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
