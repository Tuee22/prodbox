# prodbox Development Plan - Overview

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md),
[development_plan_standards.md](development_plan_standards.md),
[system-components.md](system-components.md),
[phase-0-planning-documentation.md](phase-0-planning-documentation.md),
[phase-1-runtime-cli-aws-foundations.md](phase-1-runtime-cli-aws-foundations.md),
[phase-2-gateway-dns.md](phase-2-gateway-dns.md),
[phase-3-chart-platform-vscode.md](phase-3-chart-platform-vscode.md),
[phase-4-lifecycle-canonical-paths.md](phase-4-lifecycle-canonical-paths.md),
[phase-5-public-host-validation.md](phase-5-public-host-validation.md),
[phase-6-clean-room-handoff.md](phase-6-clean-room-handoff.md),
[phase-7-aws-iam-quota-automation.md](phase-7-aws-iam-quota-automation.md)

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
8. One repository-owned custom-image doctrine: every custom Dockerfile needing Haskell builds is
   single-stage from `ubuntu:24.04`, installs `ghcup` in-image, pins GHC `9.14.1`, and does not
   create symlinked Haskell tool shims; `docker/nginx-oidc.Dockerfile` may remain based on
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
14. One in-cluster Haskell gateway runtime with config generation, heartbeat recording,
    in-memory ownership projection, DNS-write gating, REST status, and HMAC-signed event state.
15. One retained PV host-path model rooted at the configured manual PV root, defaulting to
    `.data/<namespace>/<release>/<workload>/<ordinal>/<claim>`.
16. One retained repo-local state root under `.prodbox-state/`, including namespace-local
    chart state under `.prodbox-state/<namespace>/`, AWS stack snapshots under
    `.prodbox-state/aws-test/` and `.prodbox-state/aws-eks-test/`, and the HA-RKE2 validation
    SSH key under `.prodbox-state/aws-test/`.
17. One PostgreSQL doctrine for Helm-managed application data: every supported PostgreSQL
    deployment is external, Percona-operator-backed Patroni HA with exactly three PostgreSQL
    replicas, synchronous replication, and no embedded chart-local PostgreSQL subchart.
18. One supported cluster-backed `vscode` delivery path.
19. One named validation command per major surface.
20. One explicit ledger for every compatibility or cleanup item still slated for deletion.
21. Pulumi retained for true IaC surfaces such as AWS validation resources, with no supported
    Python Pulumi program and no supported local-cluster public operator flow.

## Clean-Room Sequence

| Phase | Focus | Closure Result |
|-------|-------|----------------|
| 0 | Planning and Documentation Topology for Haskell Rewrite | The plan suite is rewritten around the Haskell end state |
| 1 | Haskell Runtime, CLI, Config, and Pulumi Foundations | One supported Haskell binary owns CLI, config, lifecycle, test, and AWS validation foundations, and the canonical frontend container-build doctrine closes under `docker/` with in-image `ghcup` and pinned GHC `9.14.1` |
| 2 | Haskell Gateway Runtime and DNS Ownership | Gateway runtime, formal verification entrypoint, and Harbor-backed gateway packaging close on the Haskell stack under the same `ubuntu:24.04` plus `ghcup` toolchain doctrine |
| 3 | Haskell Chart Platform and Cluster-Backed `vscode` Delivery | Chart orchestration, retained storage, Harbor-backed `vscode` delivery, and the Percona-operator-backed Patroni PostgreSQL doctrine close on the Haskell stack |
| 4 | Lifecycle Hardening, Pulumi Decoupling, and Python Removal | Lifecycle parity closes, Harbor bootstrap narrows to Harbor plus its storage backend, broad local-cluster Pulumi ownership is removed, and Python residue is removed |
| 5 | Public Hostname Closure and External Proof on the Haskell Stack | Public DNS, TLS, ingress, and external proof are owned by Haskell-only command paths |
| 6 | Final Clean-Room Rerun and Zero-Python Handoff | The destructive rerun contract closes with no supported Python dependency; any surviving non-Python cleanup remains phase-owned in the ledger |
| 7 | Interactive Onboarding, AWS IAM, and Quota Automation in Haskell | Interactive configuration and prompt-driven AWS administration close on Haskell-only paths, with `aws_admin_for_test_simulation.*` reserved only for test-suite simulation of that ephemeral prompt input and a shared suite-level IAM harness owning temporary operational credentials during AWS-backed reruns |

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
| Pulumi backend state | MinIO bucket `prodbox-test-pulumi-backends` on the local cluster | Local cluster bootstrap plus bounded repo-backed backend login and deleted-mount repair |
| Retained repo-local validation state | `.prodbox-state/aws-test/` and `.prodbox-state/aws-eks-test/` | Haskell Pulumi orchestration and AWS validation helpers |
| Gateway startup | `prodbox gateway start` | Haskell gateway runtime |
| Gateway DNS writes | `dns_write_gate` | In-cluster Haskell gateway ownership and DNS-write gate |
| DNS check | `prodbox dns check` | Haskell CLI |
| Chart delivery | `prodbox charts list|status|deploy|delete` | Haskell chart platform |
| Public-edge diagnostics | `prodbox host public-edge` | Haskell CLI |
| Interactive onboarding | `prodbox config setup` | Haskell CLI plus prompt-driven temporary elevated AWS credentials and AWS CLI subprocesses |
| AWS IAM and quota management | `prodbox aws policy|setup|teardown|check-quotas|request-quotas` | Haskell CLI plus AWS CLI subprocesses |
| AWS IAM validation harness | `prodbox test integration aws-iam`, `prodbox test integration all`, `prodbox test all` | Shared Haskell validation harness with idempotent IAM-user and config cleanup |
| Formal verification | `prodbox tla-check` | Haskell CLI invoking the TLA+ toolchain |
| Status and blockers | `DEVELOPMENT_PLAN/` | This plan suite |

## Current Repository State

The repository worktree implements the closed surfaces from Phases `0-7`, and the April 28, 2026
canonical `./.build/prodbox test all` rerun closes the remaining Phase `7` aggregate proof after
the earlier pre-runbook `pulumi_logged_in` failure was removed from the supported runner path. The
supported public surface is Haskell-only, the earlier unsupported cleanup residue is removed, and
the implementation uses
in-image `ghcup` with pinned GHC `9.14.1` in the frontend and gateway Dockerfiles, removes
symlinked GHC tool shims and the lifecycle-managed `haskell-toolchain` BuildKit path, aligns
`prodbox.cabal` and `cabal.project` with the explicit `ghc-9.14.1` path, installs the Percona
operator while mirroring Percona operator and PostgreSQL sidecar images, and targets
`perconapgclusters.pgv2.percona.com`. The canonical validation contract for this worktree is the
`prodbox` command surface documented below; environment-dependent AWS and public-edge proof remain
attached to those commands rather than restated here as a fresh rerun log.

### Supported Haskell Surface

- The compiled `prodbox` binary, CLI frontend, lifecycle runtime, chart platform, gateway runtime,
  AWS integrations, and test harness live under `app/`, `src/Prodbox/`, `test/`,
  `prodbox.cabal`, and `cabal.project`.
- Python source, Python packaging, Python tests, Python type stubs, Python Pulumi programs, and
  Python bridge modules are removed from the repository.
- The supported config contract is direct `Dhall -> Haskell types`; `prodbox-config.json` is not
  materialized on the supported path.
- `src/Prodbox/BuildSupport.hs` owns the `.build/prodbox` copy step and `.build/support`
  linker-support shim, while `src/Prodbox/Repo.hs` owns repository-root discovery plus canonical
  config-path resolution for the direct-Dhall command surface.
- `src/Prodbox/Aws.hs` owns both the public onboarding flow and the standalone AWS administration
  command family, with prompt-driven temporary elevated credentials on public paths and stored
  `aws_admin_for_test_simulation.*` reserved only for test-suite simulation of that prompt input,
  with the native IAM validation harness as the only supported runtime consumer.
- `src/Prodbox/TestPlan.hs`, `src/Prodbox/TestRunner.hs`, and `src/Prodbox/TestValidation.hs`
  now route `prodbox test integration aws-iam`, `prodbox test integration all`, and
  `prodbox test all` through one suite-level Haskell IAM harness.
- That shared harness now deletes any pre-existing dedicated `prodbox` IAM user and that user's
  access keys before provisioning, uses any pre-existing `aws.*` only to discover and delete the
  IAM user associated with those credentials, materializes operational `aws.*` only from
  `aws_admin_for_test_simulation.*`, and clears `aws.*` from `prodbox-config.dhall` before
  returning even when later prerequisites fail.
- Phase `7` now keeps `pulumi_logged_in` behind the visible local runbook on aggregate and
  cluster-backed suite paths, so the stale-`aws.*` leak and the pre-runbook local-cluster blocker
  are no longer the open surfaces.
- `src/Prodbox/AwsEnvironment.hs` now isolates supported AWS subprocesses from ambient host AWS
  auth and profile state before projecting repository-root credentials into the supported command
  paths.
- The target container topology lives entirely under `docker/`. Every Haskell-build Dockerfile is
  single-stage `ubuntu:24.04`, installs `ghcup` in-image, pins GHC `9.14.1`, and avoids
  symlinked Haskell tool shims; the permitted `docker/nginx-oidc.Dockerfile` Alpine-based
  exception remains unchanged.
- `src/Prodbox/CLI/Rke2.hs` owns the Harbor-first lifecycle, readiness gates, Harbor population,
  post-bootstrap Harbor-backed workload reconcile, dual-arch custom-image publication, and
  alternate-source retry during Harbor mirror publication.
- The Helm-driven lifecycle restore now retries transient upstream chart-fetch failures before
  failing the supported path.
- `docker/prodbox.Dockerfile`, `docker/gateway.Dockerfile`, and `src/Prodbox/CLI/Rke2.hs` now
  close on the `ghcup` plus `ghc-9.14.1` toolchain path with no symlinked GHC shims and no
  mounted `haskell:9.6.7-slim` BuildKit context.
- `src/Prodbox/PostgresPlatform.hs`, `src/Prodbox/Lib/ChartPlatform.hs`, and
  `charts/keycloak-postgres/` now close on namespace-local Patroni PostgreSQL HA through the
  Percona operator while preserving the three-replica, synchronous-replication,
  retained-credential, deterministic manual-PV rebinding, retained secret rendering,
  convergence gate, retained-follower reinitialization, and no-embedded-PostgreSQL guarantees.
- `src/Prodbox/CLI/Pulumi.hs` plus the stack-local YAML Pulumi definitions under
  `pulumi/aws-eks/` and `pulumi/aws-test/` retain the public Pulumi command surface for AWS
  validation IaC, while `src/Prodbox/CLI/Rke2.hs` keeps bootstrap DNS reconcile and ACME
  `ClusterIssuer` projection on the lifecycle path.
- `src/Prodbox/Infra/MinioBackend.hs`, `src/Prodbox/EffectInterpreter.hs`,
  `src/Prodbox/Infra/AwsTestStack.hs`, and `src/Prodbox/Infra/AwsEksTestStack.hs` now keep the
  repo-backed Pulumi backend on a bounded `pulumi login ... --non-interactive` path and repair a
  deleted MinIO export host-path mount by recreating the declared retained directory plus
  restarting `deployment/minio` before backend validation continues.
- `src/Prodbox/Infra/AwsTestStack.hs` and `src/Prodbox/Infra/AwsEksTestStack.hs` retain AWS
  validation stack snapshots under `.prodbox-state/aws-test/` and `.prodbox-state/aws-eks-test/`,
  with the HA-RKE2 validation SSH key stored under `.prodbox-state/aws-test/`.
- `src/Prodbox/TestRunner.hs`, `src/Prodbox/TestPlan.hs`, and `src/Prodbox/TestValidation.hs`
  own the aggregate reruns, named native validation flows, and destructive postflight restore
  path.

### Canonical Validation Gates

- Build and sync the operator binary through `cabal build --builddir=.build exe:prodbox` plus the
  `.build/prodbox` copy step.
- Run `./.build/prodbox check-code`.
- Run `./.build/prodbox test unit`.
- Run `./.build/prodbox test integration cli`.
- Run `./.build/prodbox test integration env`.
- Run the named native validation flows owned by `src/Prodbox/TestValidation.hs`.
- Run the aggregate reruns `./.build/prodbox test integration all` and `./.build/prodbox test all`.

### Interpretation

The supported architecture no longer depends on `pulumi/home`, shared `pgpool` / `repmgr`
application database ownership, the mounted `haskell:9.6.7-slim` toolchain-context path, or the
Zalando `postgres-operator` surface. Repository guidance is aligned with that state, and the
canonical Haskell validation commands now have a clean April 28, 2026 closure rerun rather than a
remaining open proof obligation.

## Haskell-Only Architecture by Surface

| Surface | Implementation | Completed In |
|---------|----------------|--------------|
| CLI frontend and command surface | `app/prodbox/Main.hs`, `src/Prodbox/CLI/Command.hs`, `src/Prodbox/CLI/Parser.hs`, `src/Prodbox/Native.hs` | Phase 1 |
| Configuration and settings | `src/Prodbox/Settings.hs`, `src/Prodbox/Repo.hs`, `prodbox-config.dhall`, `prodbox-config-types.dhall` | Phase 1 |
| Host and Kubernetes helpers | `src/Prodbox/Host.hs`, `src/Prodbox/K8s.hs` | Phase 1 |
| Container packaging and registry doctrine | `docker/`, `src/Prodbox/CLI/Rke2.hs`, `src/Prodbox/Lib/ChartPlatform.hs` | Phases 1-4 |
| Pulumi orchestration and YAML stack programs | `src/Prodbox/CLI/Pulumi.hs`, `src/Prodbox/Infra/`, `pulumi/aws-eks/Pulumi.yaml`, `pulumi/aws-eks/Main.yaml`, `pulumi/aws-test/Pulumi.yaml`, `pulumi/aws-test/Main.yaml`, `.prodbox-state/aws-test/`, `.prodbox-state/aws-eks-test/` | Phase 4 |
| DNS inspection | `src/Prodbox/Dns.hs` | Phase 2 |
| Gateway runtime and packaging | `src/Prodbox/Gateway.hs`, `src/Prodbox/Gateway/Daemon.hs`, `src/Prodbox/Gateway/Types.hs`, `docker/gateway.Dockerfile` | Phase 2 |
| Formal verification | `src/Prodbox/Tla.hs`, `documents/engineering/tla/` | Phase 2 |
| Chart platform and retained state | `src/Prodbox/CLI/Charts.hs`, `src/Prodbox/Lib/ChartPlatform.hs`, `src/Prodbox/Lib/Storage.hs`, `src/Prodbox/PostgresPlatform.hs`, `charts/`, `.prodbox-state/`; Sprint `3.3` reopens the Patroni operator surface so Helm-managed application PostgreSQL uses the Percona operator | Phase 3 |
| Public-edge diagnostics | `src/Prodbox/Host.hs` | Phase 5 |
| Onboarding and AWS administration | `src/Prodbox/Aws.hs` | Phase 7 |
| Test harness and quality gate | `src/Prodbox/BuildSupport.hs`, `src/Prodbox/CheckCode.hs`, `src/Prodbox/TestRunner.hs`, `src/Prodbox/TestValidation.hs`, `src/Prodbox/Effect.hs`, `src/Prodbox/EffectDAG.hs`, `src/Prodbox/EffectInterpreter.hs`, `src/Prodbox/Prerequisite.hs`, `src/Prodbox/Result.hs`, `src/Prodbox/Subprocess.hs`, `src/Prodbox/SupportedRuntime.hs`, `src/Prodbox/TestPlan.hs`, `test/` | Phases 1 and 4 |

## Current Execution State

Phases `0-7` are currently represented by closed repository-owned surfaces and canonical
validation contracts:

- Phase 0 defines the canonical plan suite and cleanup ledger.
- Phase 1 owns the CLI, direct-Dhall config contract, `.build/prodbox` artifact contract, and the
  Haskell test and quality framework. Sprint `1.1`, Sprint `1.2`, and Sprint `1.3` are closed,
  including the `aws_credentials_valid` prerequisite definition and the AWS-backed validation
  surfaces.
- Phase 2 owns the gateway runtime, DNS inspection surface, and TLA+ validation entrypoint; its
  repository surface closes on the Haskell daemon, config/status tooling, and the named gateway
  validation commands.
- Phase 3 owns the chart platform, retained state model, supported cluster-backed `vscode`
  delivery path, and the Percona-operator-backed Patroni PostgreSQL doctrine for Helm-managed
  workloads; it is closed on the Harbor-backed chart proofs, including the staged retained-state
  `1 -> 3` restore flow.
- Phase 4 owns Harbor-first lifecycle hardening, the narrowed Harbor-plus-storage-backend
  bootstrap exception, the public AWS-validation Pulumi surface, lifecycle-owned bootstrap DNS
  and ACME projection, and Python removal; it is closed on the destructive
  delete/install/postflight lifecycle proof and unmanaged EKS-residue cleanup.
- Phase 5 owns public-edge diagnostics and external proof.
- Phase 6 owns the destructive clean-room rerun and zero-Python repository handoff criteria.
  Sprint `6.1` and Sprint `6.2` are closed on the full destructive rerun, postflight restore, and
  zero-Python handoff contract.
- Phase 7 owns interactive onboarding, IAM automation, quota management, and the elevated
  credential proof harness. Sprint `7.3` now keeps the `pulumi_logged_in` proof behind the
  visible local runbook on aggregate and cluster-backed suite paths, while the shared IAM
  validation harness for `prodbox test integration aws-iam`,
  `prodbox test integration all`, and `prodbox test all` owns the idempotent preflight,
  temporary operational-credential lifetime, and teardown contract that prevents dedicated
  `prodbox` IAM-user leaks and clears test-created `aws.*`. The canonical `./.build/prodbox test all`
  rerun completed cleanly on April 28, 2026, including final public-edge certificate convergence
  and post-run operational-credential cleanup.

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
- Every custom Dockerfile needing Haskell builds is single-stage from `ubuntu:24.04`, installs
  `ghcup` in-image, pins GHC `9.14.1`, and does not create symlinked Haskell tool shims; the
  permitted `docker/nginx-oidc.Dockerfile` may remain based on `nginx:1.25-alpine`.
- When the pinned Haskell toolchain changes, `prodbox.cabal`, `cabal.project`, and the canonical
  build/test surfaces must be explicitly upgraded in the same change, including any required
  cabal-bound changes and full canonical validation reruns.
- The operator-authored repository-root `prodbox-config.dhall` is the single configuration source.
- The supported configuration handoff is direct `Dhall -> Haskell types`; no supported command or
  validation path may create `prodbox-config.json`, and `prodbox config compile` is not part of
  the target command surface.
- Public `prodbox config setup` and public `prodbox aws ...` paths must be able to bootstrap all
  needed AWS credentials from scratch by prompting the operator for one temporary elevated
  credential set.
- Stored admin credentials are otherwise disallowed. The one supported exception is
  `prodbox-config.dhall` `aws_admin_for_test_simulation.*`, and that section exists only for
  test-suite simulation of the ephemeral elevated credential prompt, with the native IAM test
  harness as the only supported runtime consumer.
- The named and aggregate IAM validation surfaces share one joint idempotent harness that deletes
  any pre-existing dedicated `prodbox` IAM user and all of that user's access keys before
  provisioning, uses any pre-existing `aws.*` only to discover and delete the IAM user associated
  with those credentials, materializes operational `aws.*` only from
  `aws_admin_for_test_simulation.*` to simulate the interactive public CLI workflow, and clears
  operational `aws.*` from `prodbox-config.dhall` before returning.
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
- All supported Patroni use must flow through the cluster-wide Percona operator installed on the
  canonical lifecycle path.
- Every supported Helm-managed PostgreSQL deployment must be external, Percona-operator-backed
  Patroni HA with exactly three PostgreSQL replicas, synchronous replication, and no embedded
  chart-local PostgreSQL subchart.
- Pulumi remains the exclusive provisioner and destroyer for AWS test resources on the public
  `prodbox pulumi ...` surface, while bootstrap DNS reconcile and ACME `ClusterIssuer`
  projection remain lifecycle-owned in `src/Prodbox/CLI/Rke2.hs`.
- No supported Pulumi program or orchestration path may depend on Python.
- The only supported gateway steady state is inside the cluster as a Kubernetes workload.
- The only supported DNS model is explicit per-subdomain Route 53 records; wildcard public DNS is
  not part of the supported architecture.
- The only supported `vscode` delivery path is the cluster-backed `prodbox charts` stack.
- Final handoff requires a destructive rerun from full local delete through final AWS teardown on
  the Haskell stack with no Python implementation dependency.
