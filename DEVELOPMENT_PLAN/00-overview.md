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
5. One operator-authored repository-root `prodbox-config.dhall` as the single configuration
   source, decoded directly into Haskell types with `prodbox-config-types.dhall` as the shared
   schema and no generated JSON artifact on the supported path.
6. One host build root `.build/` with the operator-facing binary at `.build/prodbox`, produced by
   the canonical `cabal build --builddir=.build exe:prodbox` invocation followed by a copy step
   that places the binary at the root of `.build/`.
7. One container build root `/opt/build`, owned only by Dockerfiles under `docker/`.
8. One repository-owned custom-image doctrine: every custom Dockerfile is single-stage from
   `ubuntu:24.04`, except `docker/nginx-oidc.Dockerfile`, which may remain based on
   `nginx:1.25-alpine`.
9. One Harbor-first steady-state registry doctrine: direct public-registry pulls are permitted
   only for Harbor and Harbor's storage backend during bootstrap, and every later supported Helm
   deployment pulls from Harbor.
10. One idempotent post-bootstrap image-reconcile path: after Harbor is healthy and externally
    serving, `prodbox` ensures required public images and all custom images are present in Harbor
    before later deployment.
11. First-class `amd64` and `arm64` image handling irrespective of local host architecture.
12. One mixed-arch cluster support contract.
13. One local-cluster-first Pulumi backend model: the local RKE2 cluster runs MinIO and stores AWS
    test-stack state in the dedicated bucket `prodbox-test-pulumi-backends`.
14. One distributed gateway runtime implemented in Haskell and deployed as an in-cluster
    Kubernetes workload with leader election and Route 53 write ownership.
15. One retained PV host-path model rooted at the configured manual PV root, defaulting to
    `.data/<namespace>/<release>/<workload>/<ordinal>/<claim>`.
16. One retained non-PV chart-state root under `.prodbox-state/<namespace>/`.
17. One PostgreSQL doctrine for Helm-managed application data: every supported PostgreSQL
    deployment is external, Patroni-based HA with exactly three PostgreSQL replicas, synchronous
    replication, and no embedded chart-local PostgreSQL subchart.
18. One supported cluster-backed `vscode` delivery path.
19. One named validation command per major surface.
20. One explicit ledger for every compatibility or cleanup item still slated for deletion.
21. Pulumi retained only for true IaC surfaces such as AWS validation resources, with no
    supported Python Pulumi program.

## Clean-Room Sequence

| Phase | Focus | Closure Result |
|-------|-------|----------------|
| 0 | Planning and Documentation Topology for Haskell Rewrite | The plan suite is rewritten around the Haskell end state |
| 1 | Haskell Runtime, CLI, Config, and Pulumi Foundations | One supported Haskell binary owns CLI, config, lifecycle, test, and AWS validation foundations, and the canonical frontend container-build doctrine closes under `docker/` |
| 2 | Haskell Gateway Runtime and DNS Ownership | Gateway runtime, formal verification entrypoint, and Harbor-backed gateway packaging close on the Haskell stack |
| 3 | Haskell Chart Platform and Cluster-Backed `vscode` Delivery | Chart orchestration, retained storage, Harbor-backed `vscode` delivery, and the external Patroni PostgreSQL doctrine close on the Haskell stack |
| 4 | Lifecycle Hardening, Pulumi Decoupling, and Python Removal | Lifecycle parity closes, Harbor bootstrap narrows to Harbor plus its storage backend, local-cluster Pulumi ownership is removed, and Python residue is removed |
| 5 | Public Hostname Closure and External Proof on the Haskell Stack | Public DNS, TLS, ingress, and external proof rerun through Haskell-only command paths |
| 6 | Final Clean-Room Rerun and Zero-Python Handoff | The destructive rerun passes with no supported Python dependency; any surviving non-Python cleanup remains phase-owned in the ledger |
| 7 | Interactive Onboarding, AWS IAM, and Quota Automation in Haskell | Interactive configuration and prompt-driven AWS administration close on Haskell-only paths, with `aws_admin.*` reserved for the native IAM test harness |

## Architecture Summary

| Surface | Canonical Target Path | Authority |
|---------|-----------------------|-----------|
| CLI control plane | `prodbox <command>` | Haskell executable |
| Host build artifacts | `.build/prodbox` | `cabal build --builddir=.build exe:prodbox` plus copy to `.build/prodbox` |
| Container build artifacts | `/opt/build` via Dockerfiles under `docker/` | Repository-owned Dockerfiles |
| Supported host runtime | `Ubuntu 24.04 LTS` with systemd | `prodbox` supported-host gate |
| Configuration | Operator-authored repository-root `prodbox-config.dhall` decoded directly into Haskell types, with `prodbox-config-types.dhall` as the shared schema and no supported `prodbox-config.json` artifact | Repository root |
| Host diagnostics | `prodbox host ensure-tools|info|check-ports|firewall|public-edge` | Haskell CLI |
| Local RKE2 lifecycle | `prodbox rke2 install|delete --yes|status|start|stop|restart|logs` | Haskell CLI with summary-oriented delete reporting |
| Registry and image reconcile | Harbor-first steady-state image sourcing with a Harbor-plus-storage-backend bootstrap exception only, plus idempotent post-bootstrap public-image populate with alternate-source retry and dual-arch image publication | Haskell lifecycle runtime |
| Kubernetes utilities | `prodbox k8s health|wait|logs` | Haskell CLI |
| AWS-backed EKS validation | `prodbox pulumi eks-resources|eks-destroy --yes` plus `prodbox test integration aws-eks` | Haskell orchestration plus Pulumi |
| AWS-backed HA RKE2 validation | `prodbox pulumi test-resources|test-destroy --yes` plus `prodbox test integration ha-rke2-aws` | Haskell orchestration plus Pulumi |
| Pulumi backend state | MinIO bucket `prodbox-test-pulumi-backends` on the local cluster | Local cluster bootstrap |
| Gateway startup | `prodbox gateway start` | Haskell gateway runtime |
| Gateway DNS writes | `dns_write_gate` | In-cluster elected Haskell gateway leader |
| DNS check | `prodbox dns check` | Haskell CLI |
| Chart delivery | `prodbox charts list|status|deploy|delete` | Haskell chart platform |
| Public-edge diagnostics | `prodbox host public-edge` | Haskell CLI |
| Interactive onboarding | `prodbox config setup` | Haskell CLI plus prompt-driven temporary elevated AWS credentials and AWS CLI subprocesses |
| AWS IAM and quota management | `prodbox aws policy|setup|teardown|check-quotas|request-quotas` | Haskell CLI plus AWS CLI subprocesses |
| Formal verification | `prodbox tla-check` | Haskell CLI invoking the TLA+ toolchain |
| Status and blockers | `DEVELOPMENT_PLAN/` | This plan suite |

## Current Repository State

The repository state as of April 23, 2026 is Haskell-only and closes on the intended architecture:

### Haskell-Only Worktree

- The compiled `prodbox` binary, CLI frontend, lifecycle runtime, chart platform, gateway runtime,
  AWS integrations, and test harness live under `app/`, `src/Prodbox/`, `test/`,
  `prodbox.cabal`, and `cabal.project`.
- Python source, Python packaging, Python tests, Python type stubs, Python Pulumi programs, and
  Python bridge modules are removed from the repository.
- The supported config contract is direct `Dhall -> Haskell types`; `prodbox-config.json` is not
  materialized on the supported path.
- `src/Prodbox/Aws.hs` owns both the public onboarding flow and the standalone AWS administration
  command family, with prompt-driven temporary elevated credentials on public paths and stored
  `aws_admin.*` reserved for the native IAM validation harness.
- The supported container topology lives entirely under `docker/` and follows the single-stage
  `ubuntu:24.04` doctrine except for the permitted `docker/nginx-oidc.Dockerfile` Alpine-based
  exception.
- `src/Prodbox/CLI/Rke2.hs` owns the Harbor-first lifecycle, readiness gates, Harbor population,
  post-bootstrap Harbor-backed workload reconcile, dual-arch custom-image publication, and
  alternate-source retry during Harbor mirror publication.
- `src/Prodbox/PostgresPlatform.hs`, `src/Prodbox/Lib/ChartPlatform.hs`, and
  `charts/keycloak-postgres/` now close on namespace-local Patroni PostgreSQL HA with three
  replicas, synchronous replication, retained credentials, deterministic manual-PV rebinding, and
  no embedded chart-local PostgreSQL subchart.
- `src/Prodbox/CLI/Pulumi.hs` and `pulumi/aws-eks/Main.yaml` plus `pulumi/aws-test/Main.yaml`
  retain Pulumi only for AWS validation IaC.
- `src/Prodbox/TestRunner.hs`, `src/Prodbox/TestPlan.hs`, and `src/Prodbox/TestValidation.hs`
  own the aggregate reruns, named native validation flows, and destructive postflight restore
  path.

### Interpretation

The repository no longer carries `pulumi/home`, shared `pgpool` or `repmgr` application database
ownership, or a broader-than-target Harbor bootstrap exception. The top-level plan and the phase
documents now close on the same end state: Haskell-only runtime ownership, AWS-only Pulumi,
Harbor-backed later workloads, and Patroni-based Helm PostgreSQL doctrine.

## Haskell-Only Architecture by Surface

| Surface | Implementation | Completed In |
|---------|----------------|--------------|
| CLI frontend and command surface | `app/prodbox/Main.hs`, `src/Prodbox/CLI/Command.hs`, `src/Prodbox/CLI/Parser.hs`, `src/Prodbox/Native.hs` | Phase 1 |
| Configuration and settings | `src/Prodbox/Settings.hs`, `prodbox-config.dhall`, `prodbox-config-types.dhall` | Phase 1 |
| Host and Kubernetes helpers | `src/Prodbox/Host.hs`, `src/Prodbox/K8s.hs` | Phase 1 |
| Container packaging and registry doctrine | `docker/`, `src/Prodbox/CLI/Rke2.hs`, `src/Prodbox/Lib/ChartPlatform.hs` | Phases 1-4 |
| Pulumi orchestration and YAML stack programs | `src/Prodbox/CLI/Pulumi.hs`, `src/Prodbox/Infra/`, `pulumi/aws-eks/Main.yaml`, `pulumi/aws-test/Main.yaml` | Phase 4 |
| DNS inspection | `src/Prodbox/Dns.hs` | Phase 2 |
| Gateway runtime and packaging | `src/Prodbox/Gateway.hs`, `src/Prodbox/Gateway/Daemon.hs`, `src/Prodbox/Gateway/Types.hs`, `docker/gateway.Dockerfile` | Phase 2 |
| Formal verification | `src/Prodbox/Tla.hs`, `documents/engineering/tla/` | Phase 2 |
| Chart platform and retained state | `src/Prodbox/CLI/Charts.hs`, `src/Prodbox/Lib/ChartPlatform.hs`, `src/Prodbox/Lib/Storage.hs`, `charts/`, `.prodbox-state/` | Phase 3 |
| Public-edge diagnostics | `src/Prodbox/Host.hs` | Phase 5 |
| Onboarding and AWS administration | `src/Prodbox/Aws.hs` | Phase 7 |
| Test harness and quality gate | `src/Prodbox/CheckCode.hs`, `src/Prodbox/TestRunner.hs`, `src/Prodbox/TestValidation.hs`, `src/Prodbox/Effect.hs`, `src/Prodbox/EffectDAG.hs`, `src/Prodbox/EffectInterpreter.hs`, `src/Prodbox/Prerequisite.hs`, `src/Prodbox/Result.hs`, `src/Prodbox/Subprocess.hs`, `src/Prodbox/SupportedRuntime.hs`, `src/Prodbox/TestPlan.hs`, `test/` | Phases 1 and 4 |

## Current Execution State

All phases are `Done`:

- Phase 0 defines the canonical plan suite and cleanup ledger.
- Phase 1 owns the CLI, direct-Dhall config contract, `.build/prodbox` artifact contract, and the
  Haskell test and quality framework.
- Phase 2 owns the gateway runtime, DNS inspection surface, and TLA+ validation entrypoint.
- Phase 3 owns the chart platform, retained state model, supported cluster-backed `vscode`
  delivery path, and the external Patroni PostgreSQL doctrine for Helm-managed workloads.
- Phase 4 owns Harbor-first lifecycle hardening, the narrowed Harbor-plus-storage-backend
  bootstrap exception, AWS-only Pulumi scope, and Python removal.
- Phase 5 owns public-edge diagnostics and external proof.
- Phase 6 owns the destructive clean-room rerun and zero-Python repository handoff criteria.
- Phase 7 owns interactive onboarding, IAM automation, quota management, and the elevated
  credential proof harness.

## Hard Constraints

- The only supported public CLI is `prodbox`.
- The rewrite preserves the full supported command matrix in
  [../documents/engineering/cli_command_surface.md](../documents/engineering/cli_command_surface.md)
  unless a later plan revision changes it explicitly.
- The only supported host runtime is `Ubuntu 24.04 LTS` with systemd.
- The host build root is `.build/` with the operator-facing binary at `.build/prodbox`, enforced
  by the canonical `cabal build --builddir=.build exe:prodbox` invocation plus a copy step.
- The container build root is `/opt/build`, and the only supported home for repository-owned
  Dockerfiles is `docker/`.
- Repository-root Dockerfiles are not part of the target architecture.
- Every custom Dockerfile is single-stage from `ubuntu:24.04`, except
  `docker/nginx-oidc.Dockerfile`, which may remain based on `nginx:1.25-alpine`.
- The operator-authored repository-root `prodbox-config.dhall` is the single configuration source.
- The supported configuration handoff is direct `Dhall -> Haskell types`; no supported command or
  validation path may create `prodbox-config.json`, and `prodbox config compile` is not part of
  the target command surface.
- Public `prodbox config setup` and public `prodbox aws ...` paths must be able to bootstrap all
  needed AWS credentials from scratch by prompting the operator for one temporary elevated
  credential set.
- Stored admin credentials are otherwise disallowed. The one supported exception is
  `prodbox-config.dhall` `aws_admin.*`, and that exception exists only for the native IAM test
  harness.
- Full cluster delete preserves exactly two retained host roots: the configured manual PV root and
  the repo-local `.prodbox-state/` root.
- Direct public-registry pulls are permitted on the supported path only for Harbor and Harbor's
  storage backend during bootstrap.
- Every later Helm deployment must obtain its images through Harbor.
- `prodbox` must idempotently ensure required public images are present in Harbor after Harbor
  bootstrap and before they are referenced by later supported cluster workloads.
- Both `amd64` and `arm64` image variants or manifests are first-class on the supported path, even
  when the operator runs `prodbox` from a host of only one architecture.
- Mixed-arch clusters are supported on the canonical lifecycle, gateway, and chart-delivery path.
- Every supported Helm-managed PostgreSQL deployment must be external, Patroni-based HA with
  exactly three PostgreSQL replicas, synchronous replication, and no embedded chart-local
  PostgreSQL subchart.
- Pulumi remains the exclusive provisioner and destroyer for AWS test resources; supported
  local-cluster platform or application deployment must not depend on Pulumi.
- No supported Pulumi program or orchestration path may depend on Python.
- The only supported gateway steady state is inside the cluster as a Kubernetes workload.
- The only supported DNS model is explicit per-subdomain Route 53 records; wildcard public DNS is
  not part of the supported architecture.
- The only supported `vscode` delivery path is the cluster-backed `prodbox charts` stack.
- Final handoff requires a destructive rerun from full local delete through final AWS teardown on
  the Haskell stack with no Python implementation dependency.
