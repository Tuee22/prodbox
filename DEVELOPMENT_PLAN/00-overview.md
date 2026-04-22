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
   that places the binary at the root of `.build/`. The operator runs `./.build/prodbox`.
7. One container build root `/opt/build`, owned only by Dockerfiles under `docker/`.
8. One repository-owned custom-image doctrine: every custom Dockerfile is single-stage from
   `ubuntu:24.04`, except `docker/nginx-oidc.Dockerfile`, which may remain based on
   `nginx:1.25-alpine`.
9. One Harbor-first steady-state registry doctrine: Harbor and the HA-chart workloads required to
   make Harbor's storage backend functional may bootstrap from public container registries, and
   every later supported cluster workload pulls from Harbor.
10. One idempotent post-bootstrap image-reconcile path: after Harbor and its storage backend are
    healthy, `prodbox` ensures required public images and all custom images are present in Harbor
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
17. One supported cluster-backed `vscode` delivery path.
18. One named validation command per major surface.
19. One explicit ledger for every Python-removal, compatibility, or cleanup item still slated for
   deletion.
20. Pulumi retained as the infrastructure engine, but with no supported Python Pulumi program.

## Clean-Room Sequence

| Phase | Focus | Closure Result |
|-------|-------|----------------|
| 0 | Planning and Documentation Topology for Haskell Rewrite | The plan suite is rewritten around the Haskell end state |
| 1 | Haskell Runtime, CLI, Config, and Pulumi Foundations | One supported Haskell binary owns CLI, config, lifecycle, test, and AWS validation foundations, and the canonical frontend container-build doctrine closes under `docker/` |
| 2 | Haskell Gateway Runtime and DNS Ownership | Gateway runtime, formal verification entrypoint, and Harbor-backed gateway packaging close on the Haskell stack |
| 3 | Haskell Chart Platform and Cluster-Backed `vscode` Delivery | Chart orchestration, retained storage, and Harbor-backed `vscode` delivery close on the Haskell stack |
| 4 | Lifecycle Hardening, Pulumi Decoupling, and Python Removal | Lifecycle parity closes, Harbor-first steady-state workload sourcing with a narrow bootstrap exception and multi-arch support land, and Python residue is removed |
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
| Registry and image reconcile | Harbor-first steady-state image sourcing with a narrow public-registry bootstrap exception for Harbor storage-backend prerequisites, plus idempotent post-bootstrap public-image populate with alternate-source retry and dual-arch image publication | Haskell lifecycle runtime |
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
| Interactive onboarding | `prodbox config setup` | Haskell CLI plus prompt-driven temporary elevated AWS credentials and AWS CLI subprocesses |
| AWS IAM and quota management | `prodbox aws policy|setup|teardown|check-quotas|request-quotas` | Haskell CLI plus AWS CLI subprocesses, with public elevated operations sourced from interactive prompts rather than stored `aws_admin.*` |
| Formal verification | `prodbox tla-check` | Haskell CLI invoking the TLA+ toolchain |
| Status and blockers | `DEVELOPMENT_PLAN/` | This plan suite |

## Current Repository State

The repository state as of April 21, 2026 is the Haskell-only architecture described by this
plan, with the reopened Phase `4` lifecycle bootstrap work and the dependent Phase `7` aggregate
credential-boundary proof both now revalidated and closed:

### Haskell-Only Worktree

- The compiled Haskell `prodbox` binary exists under `app/`, `src/Prodbox/`, `test/`,
  `prodbox.cabal`, and `cabal.project`.
- All Python source (`src/prodbox/`, `tests/`, `typings/`), Python packaging (`pyproject.toml`,
  `poetry.toml`, `.python-version`), and Python bridge modules (`Backend/Python.hs`,
  `PythonEnv.hs`) have been deleted from the repository.
- The frontend request path and supported-runtime helpers are now free of residual Python-era
  scaffolding: `src/Prodbox/CLI/Command.hs` closes on a native-only request ADT,
  `app/prodbox/Main.hs` dispatches only native Haskell commands, and
  `src/Prodbox/SupportedRuntime.hs` no longer exports Python-named context fields.
- The tracked schema artifact is `prodbox-config-types.dhall`; the operator-authored repo-root
  config is `prodbox-config.dhall`, written by `prodbox config setup` and ignored from version
  control. `src/Prodbox/Settings.hs` owns Dhall decoding, masked display, and validation with no
  supported JSON materialization path. `src/Prodbox/Aws.hs` owns `config setup` plus
  `aws policy|setup|teardown|check-quotas|request-quotas`.
- Public onboarding and standalone AWS administration now match the supported boundary:
  `src/Prodbox/Aws.hs` keeps the public `config setup` and public `aws ...` flows on prompt-driven
  temporary elevated credentials, while stored `aws_admin.*` remains test-harness-only.
- `src/Prodbox/SupportedRuntime.hs` now contains only the retained supported-runtime helpers; the
  retired non-test `aws_admin.*` recovery path is no longer part of the worktree.
- All Pulumi programs are YAML-based: `pulumi/home/Main.yaml`, `pulumi/aws-eks/Main.yaml`, and
  `pulumi/aws-test/Main.yaml`. The root `Pulumi.yaml` uses `runtime: yaml`.
- The AWS validation Pulumi programs take their operator-CIDR and SSH-public-key inputs from
  explicit stack config written by the Haskell infra modules rather than `std:getenv` calls inside
  the YAML runtime.
- The current repository has three supported container-build definitions under `docker/`:
  `docker/prodbox.Dockerfile`, `docker/gateway.Dockerfile`, and `docker/nginx-oidc.Dockerfile`.
- `docker/prodbox.Dockerfile` and `docker/gateway.Dockerfile` are single-stage `ubuntu:24.04`
  builds that preserve the `/opt/build` artifact contract and mount the official
  `haskell:9.6.7-slim` toolchain image as a BuildKit context during publication. The gateway
  image now also installs the official AWS CLI bundle per `TARGETARCH` so the in-pod Route 53
  subprocess path remains available without leaving the single-stage `ubuntu:24.04` doctrine. The
  repository-root `Dockerfile` is no longer part of the worktree.
- `docker/nginx-oidc.Dockerfile` remains the permitted `nginx:1.25-alpine` exception and is now
  published through the same Harbor-backed dual-arch custom-image flow as the gateway image.
- The in-cluster gateway steady state is repo-rootless: `app/prodbox/Main.hs` now permits
  repo-rootless `gateway start|status`, and `charts/gateway/` injects AWS auth through the
  `gateway-aws-credentials` secret while probing `/v1/state` over HTTP on the in-pod REST port.
- `src/Prodbox/ContainerImage.hs` defines the canonical supported public-image inventory and the
  Harbor targets used by `src/Prodbox/CLI/Rke2.hs`, `src/Prodbox/Lib/ChartPlatform.hs`, and
  `pulumi/home/Main.yaml`.
- The supported local lifecycle now installs Harbor, bootstraps MinIO from public
  `quay.io/minio/*` refs so the local backend can come up, mirrors required public images and
  publishes custom images into Harbor, then reconciles MinIO and later supported workloads back
  onto Harbor-backed image references.
- The Harbor public-image mirror path now retries alternate configured upstream candidates when a
  preferred source publishes a valid manifest list but later fails during
  `docker buildx imagetools create`, so transient public-registry rate limits do not strand the
  post-bootstrap Harbor reconcile.
- The updated target doctrine is now reflected directly in the runtime: Harbor and the HA-chart
  workloads needed to make Harbor's storage backend functional may bootstrap from public
  registries, then `prodbox` populates Harbor idempotently and keeps later supported deployments
  on Harbor-backed image references.
- The dual-arch image publication and Harbor inventory reconcile logic remain implemented for both
  `amd64` and `arm64` through per-platform `buildx` publication plus manifest composition
  irrespective of local host architecture.
- The supported lifecycle now also waits for a stable Harbor external-serving window before Docker
  login, image mirror, or image publication continues on a fresh cluster.
- `prodbox rke2 delete --yes` now reports AWS destroy disposition, local substrate cleanup,
  managed kubeconfig handling, and preserved host roots as a short success narrative instead of
  streaming raw Pulumi login output or successful uninstall-script trace noise.
- `src/Prodbox/CLI/Pulumi.hs` now projects configured ZeroSSL EAB credentials into the supported
  cert-manager `ClusterIssuer` through `externalAccountBinding` plus the
  `cert-manager/acme-eab-credentials` secret.
- `CheckCode.hs` runs `cabal build --builddir=.build all` without any Python tooling and syncs the
  operator-facing host binary to `.build/prodbox` after a successful build.
- `TestRunner.hs` runs Haskell test suites via `cabal test`, the native `cli` and `env` suites via
  `test/integration/cli/Main.hs` and `test/integration/env/Main.hs`, and the named real-world
  integration proofs via `src/Prodbox/TestValidation.hs`.
- `TestRunner.hs` and `TestValidation.hs` now re-invoke the native CLI through the canonical
  `./.build/prodbox` path during aggregate workflows, so nested suite-side binary syncs do not
  break later native phases.
- `TestPlan.hs`, `Prerequisite.hs`, and `EffectInterpreter.hs` now gate AWS-backed named validation
  suites on live AWS credential, Route 53, Pulumi-login, and native IAM harness checks before the
  validation bodies run.
- `EffectInterpreter.hs` now checks Pulumi login against the canonical repo-backed MinIO backend:
  it port-forwards MinIO, ensures the `prodbox-test-pulumi-backends` bucket exists, and runs
  `pulumi whoami` under the explicit backend environment instead of relying on ambient host Pulumi
  state.
- `TestRunner.hs` now waits for `prodbox host public-edge` to report
  `CLASSIFICATION=ready-for-external-proof` during supported-runtime bootstrap and postflight
  before external `charts-vscode` proof continues.
- The canonical validation surfaces are `./.build/prodbox check-code`,
  `./.build/prodbox test unit`, `./.build/prodbox test integration cli`,
  `./.build/prodbox test integration env`, and the named native validation flows owned by
  `src/Prodbox/TestValidation.hs`.
- Missing repo-root config now fails fast with explicit `./.build/prodbox config setup` guidance
  rather than a raw file-open exception from the Dhall loader.
- The supported Haskell command matrix is `config setup|show|validate`,
  `aws policy|setup|teardown|check-quotas|request-quotas`,
  `host ensure-tools|check-ports|info|firewall|public-edge`, `rke2`, `pulumi`, `dns check`,
  `gateway start|status|config-gen`, `charts`, `k8s health|wait|logs`, `check-code`, `test`, and
  `tla-check`.
- Root guidance docs and the governed docs are aligned with the implemented Phase `7` credential
  boundary.
- The latest reruns now pass `./.build/prodbox check-code`, `./.build/prodbox test unit`,
  `./.build/prodbox test integration cli`, `./.build/prodbox test integration env`,
  `./.build/prodbox test integration aws-iam`, `./.build/prodbox test integration lifecycle`,
  `./.build/prodbox rke2 install`, and `./.build/prodbox test all`.
- The aggregate post-test restore now reaches the supported public-edge state with
  `CLASSIFICATION=ready-for-external-proof`.

### Interpretation

The repository remains Haskell-only. No Python source, Python toolchain, Python Pulumi program,
or Python bridge module remains in the repository. The reopened lifecycle work is now closed: the
target Harbor-first steady-state architecture with a narrow public-registry bootstrap exception is
implemented and revalidated through the destructive lifecycle and aggregate reruns.

## Haskell-Only Architecture by Surface

| Surface | Implementation | Completed In |
|---------|----------------|--------------|
| CLI frontend and command surface | `app/prodbox/Main.hs`, `src/Prodbox/CLI/Command.hs`, `src/Prodbox/CLI/Parser.hs`, `src/Prodbox/Native.hs` | Phase 1 |
| Configuration and settings | `src/Prodbox/Settings.hs`, `prodbox-config.dhall`, `prodbox-config-types.dhall` | Phase 1 |
| Host and Kubernetes helpers | `src/Prodbox/Host.hs`, `src/Prodbox/K8s.hs` | Phase 1 |
| Container packaging and registry doctrine | `docker/`, `src/Prodbox/CLI/Rke2.hs`, `src/Prodbox/Lib/ChartPlatform.hs` | Phases 1-4 |
| Pulumi orchestration and YAML stack programs | `src/Prodbox/CLI/Pulumi.hs`, `src/Prodbox/Infra/`, `pulumi/home/Main.yaml`, `pulumi/aws-eks/Main.yaml`, `pulumi/aws-test/Main.yaml` | Phase 4 |
| DNS inspection | `src/Prodbox/Dns.hs` | Phase 2 |
| Gateway runtime and packaging | `src/Prodbox/Gateway.hs`, `src/Prodbox/Gateway/Daemon.hs`, `src/Prodbox/Gateway/Types.hs`, `docker/gateway.Dockerfile` | Phase 2 |
| Formal verification | `src/Prodbox/Tla.hs`, `documents/engineering/tla/` | Phase 2 |
| Chart platform and retained state | `src/Prodbox/CLI/Charts.hs`, `src/Prodbox/Lib/ChartPlatform.hs`, `src/Prodbox/Lib/Storage.hs`, `charts/`, `.prodbox-state/` | Phase 3 |
| Public-edge diagnostics | `src/Prodbox/Host.hs` | Phase 5 |
| Onboarding and AWS administration | `src/Prodbox/Aws.hs` | Phase 7 |
| Test harness and quality gate | `src/Prodbox/CheckCode.hs`, `src/Prodbox/TestRunner.hs`, `src/Prodbox/TestValidation.hs`, `src/Prodbox/Effect.hs`, `src/Prodbox/EffectDAG.hs`, `src/Prodbox/EffectInterpreter.hs`, `src/Prodbox/Prerequisite.hs`, `src/Prodbox/Result.hs`, `src/Prodbox/Subprocess.hs`, `src/Prodbox/SupportedRuntime.hs`, `src/Prodbox/TestPlan.hs`, `test/` | Phase 1, Phase 4 |

## Current Execution State

Phases `0-7` are `Done`:

- Phase 0 defines the canonical plan suite and cleanup ledger.
- Phase 1 owns the CLI, direct-Dhall config contract, `.build/prodbox` artifact contract, and the
  Haskell test and quality framework.
- Phase 2 owns the gateway runtime, DNS inspection surface, and TLA+ validation entrypoint.
- Phase 3 owns the chart platform, retained state model, and supported cluster-backed `vscode`
  delivery path.
- Phase 4 owns Harbor-first lifecycle hardening, YAML Pulumi definitions, Python removal, and the
  supported bootstrap exception for Harbor and storage-backend prerequisites.
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
  by the canonical `cabal build --builddir=.build exe:prodbox` invocation plus a copy step. The
  operator runs `./.build/prodbox`.
- The container build root is `/opt/build`, and the only supported home for repository-owned
  Dockerfiles is `docker/`.
- Repository-root Dockerfiles are not part of the target architecture.
- Every custom Dockerfile is single-stage from `ubuntu:24.04`, except
  `docker/nginx-oidc.Dockerfile`, which may remain based on `nginx:1.25-alpine`.
- The operator-authored repository-root `prodbox-config.dhall` is the single configuration source
  unless a later plan revision changes that rule explicitly.
- The supported configuration handoff is direct `Dhall -> Haskell types`; no supported command or
  validation path may create `prodbox-config.json`, and `prodbox config compile` is not part of
  the target command surface.
- Public `prodbox config setup` and public `prodbox aws ...` paths must be able to bootstrap all
  needed AWS credentials from scratch by prompting the operator for one temporary elevated
  credential set.
- Stored admin credentials are otherwise disallowed. The one supported exception is
  `prodbox-config.dhall` `aws_admin.*`, and that exception exists only for the native IAM test
  harness.
- No supported non-test command or runtime helper may read or use `aws_admin.*`.
- The configured manual PV host root defaults to `.data/` and is reserved for PV contents only.
- Full cluster delete preserves exactly two retained host roots: the configured manual PV root and
  the repo-local `.prodbox-state/` root.
- Harbor and the HA-chart workloads required to make Harbor's storage backend functional may
  bootstrap from public container registries on the supported path.
- Every later cluster deployment must obtain its images through Harbor; direct non-Harbor workload
  pulls outside that bootstrap exception are not part of the supported architecture.
- `prodbox` must idempotently ensure required public images are present in Harbor after bootstrap
  and before they are referenced by later supported cluster workloads.
- Both `amd64` and `arm64` image variants or manifests are first-class on the supported path, even
  when the operator runs `prodbox` from a host of only one architecture.
- Mixed-arch clusters are supported on the canonical lifecycle, gateway, and chart-delivery path.
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
