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
   create symlinked Haskell tool shims; the supported public edge does not depend on a
   repository-owned nginx auth-proxy image.
9. One Harbor-first steady-state registry doctrine: direct public-registry pulls are permitted
   only for Harbor and Harbor's storage backend during bootstrap, and every later supported Helm
   deployment pulls from Harbor.
10. One idempotent post-bootstrap image-reconcile path: after Harbor is healthy and externally
    serving, `prodbox` ensures required public images and all custom images are present in Harbor
    before later deployment.
11. One native-architecture container-build doctrine: `amd64` hosts build `amd64` images, and
    `arm64` hosts build `arm64` images.
12. Native `arm64` container builds work on native `arm64` Docker daemons, including Apple
    Silicon with Colima, while cross-arch builds, `docker buildx`, and mixed-arch clusters are
    unsupported.
13. One local-cluster-first Pulumi backend model: the local RKE2 cluster runs MinIO and stores AWS
    test-stack state in the dedicated bucket `prodbox-test-pulumi-backends`.
14. One in-cluster Haskell gateway runtime with config generation, HTTP `/v1/state`
    observability, heartbeat recording, in-memory ownership projection, DNS-write gating,
    Orders-backed interval validation, and HMAC-signed event state. Gateway config still carries
    certificate and socket metadata, but the closed repository surface does not materialize
    peer-transport behavior from those fields today.
15. One self-managed public-edge doctrine where MetalLB exposes Envoy Gateway, Kubernetes Gateway
    API owns Layer 7 routes, cert-manager owns listener TLS, Keycloak remains the identity
    provider, every externally reachable app or dashboard lives under the single hostname
    `test.resolvefintech.com`, Envoy enforces Keycloak-backed JWT auth and RBAC on explicit path
    prefixes such as `/vscode`, `/api`, `/ws`, `/auth`, and later supported admin paths, and the
    steady-state request path does not synchronously depend on Keycloak or Redis.
16. One retained PV host-path model rooted at the configured manual PV root, defaulting to
    `.data/<namespace>/<release>/<workload>/<ordinal>/<claim>`.
17. One retained repo-local state root under `.prodbox-state/`, including namespace-local
    chart state under `.prodbox-state/<namespace>/`, AWS stack snapshots under
    `.prodbox-state/aws-test/` and `.prodbox-state/aws-eks-test/`, and the HA-RKE2 validation
    SSH key under `.prodbox-state/aws-test/`.
18. One PostgreSQL doctrine for Helm-managed application data: every supported PostgreSQL
    deployment is external, Percona-operator-backed Patroni HA with exactly three PostgreSQL
    replicas, synchronous replication, and no embedded chart-local PostgreSQL subchart.
19. One supported public workload catalog comprising the cluster-backed `vscode` browser route, a
    JWT-protected API route, a WebSocket route, and path-routed operational dashboards such as
    Harbor and MinIO, all on the same public hostname.
20. One explicit single-host routing model for the public edge:
    `https://test.resolvefintech.com/<service-path>`, with one public DNS record, one public
    certificate, and no dedicated identity, browser-app, API, or WebSocket hostnames.
21. One repo-owned Redis workload path for supported realtime workloads and any later explicit
    external rate-limit service, only as shared application state and never as an Envoy JWT cache.
22. One explicit public-edge transport boundary where public TLS terminates at Envoy, backend HTTP
    remains the current supported workload default, and backend TLS or mTLS requires later
    explicit doctrine ownership.
23. One supported WebSocket connection-lifetime doctrine: auth at connection setup, one live
    upgraded connection pinned to one backend pod until disconnect, reconnect-safe state outside
    the pod, and readiness-based drain before pod exit.
24. One named validation command per major surface.
25. One explicit ledger for compatibility or cleanup history that preserves completed removals and
    closes with zero pending supported-path residue.
26. Pulumi retained for true IaC surfaces such as AWS validation resources, with no supported
    Python Pulumi program and no supported local-cluster public operator flow.

## Clean-Room Sequence

| Phase | Focus | Closure Result |
|-------|-------|----------------|
| 0 | Planning and Documentation Topology for Haskell Rewrite | The plan suite is rewritten around the Haskell end state |
| 1 | Haskell Runtime, CLI, Config, and Pulumi Foundations | One supported Haskell binary owns CLI, config, lifecycle, test, and AWS validation foundations, and the config contract closes on one canonical public hostname with no `example.com` residue |
| 2 | Haskell Gateway Runtime and DNS Ownership | Gateway runtime, formal verification entrypoint, Harbor-backed gateway packaging, and the single-record Route 53 ownership contract close on the Haskell stack under the same `ubuntu:24.04` plus `ghcup` toolchain doctrine |
| 3 | Haskell Chart Platform and Public Workload Delivery | Chart orchestration, retained storage, Harbor-backed browser/API/WebSocket delivery, path-routed admin delivery, Keycloak-backed Envoy auth and RBAC, Redis-backed realtime state, and the Percona-operator-backed Patroni PostgreSQL doctrine close on the Haskell stack |
| 4 | Lifecycle Hardening, Pulumi Decoupling, and Python Removal | Lifecycle parity closes, Harbor bootstrap narrows to Harbor plus its storage backend, bootstrap DNS or certificate issuance collapse to the one-host doctrine, broad local-cluster Pulumi ownership is removed, and Python residue is removed |
| 5 | Public Hostname Closure and External Proof on the Haskell Stack | Public DNS, TLS, Gateway API, and external proof close on one public hostname with path-routed app and admin surfaces owned by Haskell-only command paths |
| 6 | Final Clean-Room Rerun and Zero-Python Handoff | The destructive rerun contract closes with no supported Python dependency and no surviving single-host public-edge cleanup in the ledger |
| 7 | Interactive Onboarding, AWS IAM, and Quota Automation in Haskell | Interactive configuration and prompt-driven AWS administration close on Haskell-only paths, with one canonical public hostname, no placeholder domains, and `aws_admin_for_test_simulation.*` reserved only for test-suite simulation of that ephemeral prompt input |

## Architecture Summary

| Surface | Canonical Target Path | Authority |
|---------|-----------------------|-----------|
| CLI control plane | `prodbox <command>` | Haskell executable |
| Host build artifacts | `.build/prodbox` | `cabal build --builddir=.build exe:prodbox` plus copy to `.build/prodbox` |
| Container build artifacts | `/opt/build` via Dockerfiles under `docker/` | Repository-owned Dockerfiles |
| Supported host runtime | `Ubuntu 24.04 LTS` with systemd | `prodbox` supported-host gate |
| Configuration | Operator-authored repository-root `prodbox-config.dhall` decoded directly into Haskell types, with `prodbox-config-types.dhall` as the shared schema and no supported `prodbox-config.json` artifact | Repository root |
| Host diagnostics | `prodbox host ensure-tools|check-ports|info|firewall|public-edge` | Haskell CLI |
| Local RKE2 lifecycle | `prodbox rke2 install|delete --yes|status|start|stop|restart|logs` | Haskell CLI with summary-oriented delete reporting |
| Registry and image reconcile | Harbor-first steady-state image sourcing with a Harbor-plus-storage-backend bootstrap exception only, plus idempotent post-bootstrap public-image populate with alternate-source retry and native-host-architecture image publication for the Envoy Gateway target edge and chart workloads | Haskell lifecycle runtime |
| Kubernetes utilities | `prodbox k8s health|wait|logs` | Haskell CLI |
| AWS-backed EKS validation | `prodbox pulumi eks-resources|eks-destroy --yes` plus `prodbox test integration aws-eks` | Haskell orchestration plus Pulumi |
| AWS-backed HA RKE2 validation | `prodbox pulumi test-resources|test-destroy --yes` plus `prodbox test integration ha-rke2-aws` | Haskell orchestration plus Pulumi |
| Pulumi backend state | MinIO bucket `prodbox-test-pulumi-backends` on the local cluster | Local cluster bootstrap plus bounded repo-backed backend login and deleted-mount repair |
| Retained repo-local validation state | `.prodbox-state/aws-test/` and `.prodbox-state/aws-eks-test/` | Haskell Pulumi orchestration and AWS validation helpers |
| Gateway startup | `prodbox gateway start <config-path>` | Haskell gateway runtime |
| Public workload runtime | `prodbox workload start` | Haskell runtime selected through `PRODBOX_WORKLOAD_MODE=api|websocket` for the supported path-routed API and real-WebSocket surfaces behind the shared public hostname |
| Gateway DNS writes | `dns_write_gate` | In-cluster Haskell gateway ownership and DNS-write gate for the single canonical public record |
| DNS check | `prodbox dns check` | Haskell CLI |
| Shared public-edge route catalog | `src/Prodbox/PublicEdge.hs` | Haskell-owned shared-host path catalog and issuer derivation for application and admin routes |
| Chart delivery | `prodbox charts list|status <chart>|deploy <chart>|delete <chart> [--yes]` | Haskell chart platform with Keycloak as IdP, Envoy-authenticated path-routed browser and admin delivery, JWT-protected API delivery, and the active Redis-backed WebSocket implementation path |
| Public-edge diagnostics | `prodbox host public-edge` | Haskell CLI on a single-host Gateway API and Envoy Gateway doctrine, including path-route classification for app and admin surfaces |
| Public-edge auth model | Envoy-enforced Keycloak JWT auth and RBAC on the shared hostname, with explicit bearer-token carriers, browser return paths, and JWKS metadata ownership | Keycloak issuer plus Envoy policy |
| Public-edge transport boundary | Public listener TLS terminates at Envoy on the supported path; backend HTTP remains the current workload default and backend TLS or mTLS requires later explicit doctrine ownership | Haskell lifecycle plus chart doctrine |
| Optional realtime-state model | Redis-backed shared state for supported WebSocket workloads today and any later explicit external rate-limit service | Haskell chart platform plus application workload doctrine |
| Interactive onboarding | `prodbox config setup` | Haskell CLI plus prompt-driven temporary elevated AWS credentials and AWS CLI subprocesses |
| AWS IAM and quota management | `prodbox aws policy|setup|teardown|check-quotas|request-quotas` | Haskell CLI plus AWS CLI subprocesses |
| AWS IAM validation harness | `prodbox test integration aws-iam`, `prodbox test integration all`, `prodbox test all` | Shared Haskell validation harness with idempotent IAM-user and config cleanup |
| Formal verification | `prodbox tla-check` | Haskell CLI invoking the TLA+ toolchain |
| Code quality gate | `prodbox check-code` | Haskell CLI plus governed doctrine-alignment enforcement |
| Status and blockers | `DEVELOPMENT_PLAN/` | This plan suite |

## Current Repository State

The repository worktree now implements the final Haskell-only rewrite architecture. The supported
operator surface is `prodbox`, the supported configuration contract is direct
`Dhall -> Haskell types` rooted at `prodbox-config.dhall`, and the supported build topology
remains `.build/prodbox` on the host plus `/opt/build` inside repository-owned Dockerfiles.
`prodbox check-code` enforces the governed doctrine-alignment gate, the Haskell gateway runtime
plus status path close on the implemented HTTP `/v1/state` payload and daemon timing-validation
contract, the final clean-room handoff closes on the canonical rerun surface, and the earlier
unsupported Python runtime and tooling surfaces remain removed.

The supported public edge now uses MetalLB, Envoy Gateway, Gateway API, cert-manager, and
Keycloak on the single public hostname `test.resolvefintech.com`. Every externally reachable
application or operational dashboard routes through explicit shared-host paths such as `/auth`,
`/vscode`, `/api`, `/ws`, `/harbor`, and `/minio`, protected by Keycloak-backed JWT auth or RBAC
at Envoy, with one Route 53 record and one listener certificate. The shipped API route validates
bearer tokens locally at Envoy from Keycloak issuer metadata plus JWKS-backed signing keys,
browser-auth and direct-OIDC flows stay explicit on their owned paths, WebSocket workloads close
on a true `/ws` upgrade with Redis-backed shared state and readiness-based drain, and public TLS
terminates at Envoy while backend TLS or mTLS remains outside the supported chart-workload
contract.

Root guidance plus the governed command-surface, public-edge, and chart-platform doctrine docs now
describe that same shared-host route catalog and credential boundary, so the documented operator
path matches the implemented one-host public edge.

The lifecycle is Harbor-first and native-architecture only: Harbor plus its storage backend may
bootstrap from public registries, every later Helm deployment pulls through Harbor, and `amd64`
or `arm64` hosts build and publish only their own architecture. The stack closes on in-image
`ghcup` with pinned GHC `9.14.1` in the frontend and gateway Dockerfiles, the Percona operator-
backed Patroni PostgreSQL doctrine, and config-selected MetalLB L2 or BGP advertisement. The
cleanup ledger preserves completed history with zero pending supported-path residue. The separate
Haskell distributed gateway daemon remains distinct from the Envoy Gateway public edge.

The canonical validation contract for this worktree is the `prodbox` command surface documented
below; environment-dependent AWS and public-edge proof remain attached to those commands rather
than restated here as a fresh rerun log.

### Supported Haskell Surface

- The Haskell sources, Cabal definitions, and tests that build the supported `prodbox` binary and
  own the CLI frontend, lifecycle runtime, chart platform, public-workload runtime, gateway
  runtime, AWS integrations, and test harness live under `app/`, `src/Prodbox/`, `test/`,
  `prodbox.cabal`, and `cabal.project`.
- Python source, Python packaging, Python tests, Python type stubs, Python Pulumi programs, and
  Python bridge modules are removed from the repository.
- The supported config contract is direct `Dhall -> Haskell types`; `prodbox-config.json` is not
  materialized on the supported path.
- `src/Prodbox/BuildSupport.hs` owns the `.build/prodbox` copy step and `.build/support`
  linker-support shim, while `src/Prodbox/Repo.hs` owns repository-root discovery plus canonical
  config-path resolution for the direct-Dhall command surface.
- `src/Prodbox/CheckCode.hs` now fails on repository-owned workflow or git-hook surfaces before it
  runs Fourmolu, HLint, warning-clean Cabal builds, and the operator-binary sync step, closing on
  the governed doctrine-alignment contract described by
  `documents/engineering/code_quality.md`. The repo-owned policy scan excludes generated or
  retained runtime roots such as `.build/`, `dist-newstyle/`, `.prodbox-state/`, and `.data/`.
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
- Phase `7` keeps `pulumi_logged_in` behind the visible local runbook on aggregate and
  cluster-backed suite paths.
- `src/Prodbox/AwsEnvironment.hs` now isolates supported AWS subprocesses from ambient host AWS
  auth and profile state before projecting repository-root credentials into the supported command
  paths.
- The target container topology lives entirely under `docker/`. Every Haskell-build Dockerfile is
  single-stage `ubuntu:24.04`, installs `ghcup` in-image, pins GHC `9.14.1`, and avoids
  symlinked Haskell tool shims.
- `src/Prodbox/CLI/Rke2.hs` owns the Harbor-first lifecycle, readiness gates, Harbor population,
  post-bootstrap Harbor-backed workload reconcile, native-host-architecture custom-image
  publication, and alternate-source retry during Harbor mirror publication. The current lifecycle
  installs Envoy Gateway and the Harbor-backed Envoy image set for the supported public edge.
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
- `src/Prodbox/Infra/AwsTestStack.hs` and `src/Prodbox/Infra/AwsEksTestStack.hs` generate and
  retain AWS validation stack snapshots under `.prodbox-state/aws-test/` and
  `.prodbox-state/aws-eks-test/`, with the HA-RKE2 validation SSH key stored under
  `.prodbox-state/aws-test/`.
- `src/Prodbox/CLI/Rke2.hs` now closes the supported lifecycle on the clean-room Envoy Gateway
  and Percona reconcile path with no retained Traefik or pre-Percona operator migration shims.
- `src/Prodbox/Infra/AwsTestStack.hs` and `src/Prodbox/Infra/AwsEksTestStack.hs` now sync only
  the supported retained AWS-validation stack inputs and no longer remove older Pulumi AWS
  provider-key layouts on the supported path.
- `src/Prodbox/PublicEdge.hs` now centralizes the single-host route catalog, canonical route
  URLs, and Keycloak issuer derivation consumed by lifecycle, DNS, chart, workload, host-
  diagnostic, and native validation surfaces.
- `src/Prodbox/Gateway.hs`, `src/Prodbox/Gateway/Daemon.hs`, and `src/Prodbox/Gateway/Types.hs`
  own the current Haskell gateway surface, including the HTTP `/v1/state` payload with
  `event_hashes` and `heartbeat_age_seconds`, plus Orders-backed interval validation. The parsed
  certificate, key, CA, and socket metadata remain in the current model even though the closed
  runtime surface does not yet materialize peer transport from them.
- `src/Prodbox/TestRunner.hs`, `src/Prodbox/TestPlan.hs`, and `src/Prodbox/TestValidation.hs`
  own the aggregate reruns, named native validation flows, and destructive postflight restore
  path.

### Canonical Validation Gates

- Build and sync the operator binary through `cabal build --builddir=.build exe:prodbox` plus the
  `.build/prodbox` copy step.
- Run `prodbox check-code`.
- Run `prodbox test unit`.
- Run `prodbox test integration cli`.
- Run `prodbox test integration env`.
- Run the named native validation flows owned by `src/Prodbox/TestValidation.hs`.
- Run the aggregate reruns `prodbox test integration all` and `prodbox test all`.

### Interpretation

The supported architecture closes on the Haskell-only clean-room lifecycle, the AWS-validation-
only `prodbox pulumi ...` surface, the Harbor-first registry doctrine, and the Percona-backed
Patroni application-database path. Compatibility-cleanup history now lives only in
[legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md).

## Haskell-Only Architecture by Surface

| Surface | Implementation | Completed In |
|---------|----------------|--------------|
| CLI frontend and command surface | `app/prodbox/Main.hs`, `src/Prodbox/CLI/Command.hs`, `src/Prodbox/CLI/Parser.hs`, `src/Prodbox/Native.hs` | Phase 1 |
| Configuration and settings | `src/Prodbox/Settings.hs`, `src/Prodbox/Repo.hs`, `prodbox-config.dhall`, `prodbox-config-types.dhall` | Phase 1 |
| Host and Kubernetes helpers | `src/Prodbox/Host.hs`, `src/Prodbox/K8s.hs` | Phase 1 |
| Container packaging and registry doctrine | `docker/`, `src/Prodbox/CLI/Rke2.hs`, `src/Prodbox/ContainerImage.hs`, `src/Prodbox/Lib/ChartPlatform.hs` | Phases 1-4 |
| Pulumi orchestration and YAML stack programs | `src/Prodbox/CLI/Pulumi.hs`, `src/Prodbox/Infra/`, `pulumi/aws-eks/Pulumi.yaml`, `pulumi/aws-eks/Main.yaml`, `pulumi/aws-test/Pulumi.yaml`, `pulumi/aws-test/Main.yaml`, plus generated state under `.prodbox-state/aws-test/` and `.prodbox-state/aws-eks-test/` | Phase 4 |
| DNS inspection | `src/Prodbox/Dns.hs` | Phase 2 |
| Shared public-edge route catalog | `src/Prodbox/PublicEdge.hs` | Phase 3 |
| Gateway runtime and packaging | `src/Prodbox/Gateway.hs`, `src/Prodbox/Gateway/Daemon.hs`, `src/Prodbox/Gateway/Types.hs`, `docker/gateway.Dockerfile` | Phase 2 |
| Formal verification | `src/Prodbox/Tla.hs`, `documents/engineering/tla/` | Phase 2 |
| Chart platform and retained state | `src/Prodbox/CLI/Charts.hs`, `src/Prodbox/Lib/ChartPlatform.hs`, `src/Prodbox/Lib/Storage.hs`, `src/Prodbox/PostgresPlatform.hs`, `charts/`, plus generated retained non-PV state under `.prodbox-state/` and the Percona-operator-backed Patroni application-database contract | Phase 3 |
| Public workload runtime | `src/Prodbox/Workload.hs` | Phase 3 |
| Public-edge diagnostics | `src/Prodbox/Host.hs` | Phase 5 |
| Onboarding and AWS administration | `src/Prodbox/Aws.hs`, `src/Prodbox/AwsEnvironment.hs`, `src/Prodbox/CLI/Parser.hs`, `src/Prodbox/Native.hs` | Phase 7 |
| Test harness and quality gate | `src/Prodbox/BuildSupport.hs`, `src/Prodbox/CheckCode.hs`, `src/Prodbox/TestRunner.hs`, `src/Prodbox/TestValidation.hs`, `src/Prodbox/Effect.hs`, `src/Prodbox/EffectDAG.hs`, `src/Prodbox/EffectInterpreter.hs`, `src/Prodbox/Prerequisite.hs`, `src/Prodbox/Result.hs`, `src/Prodbox/Subprocess.hs`, `src/Prodbox/TestPlan.hs`, `test/` | Phases 1 and 4 |

## Current Execution State

Phase `0` is closed on the plan suite. Phases `1`, `2`, `3`, `4`, `5`, `6`, and `7` are closed
on the implemented repository architecture:

- Phase 0 defines the canonical plan suite and cleanup ledger.
- Phase 1 owns the CLI, direct-Dhall config contract, `.build/prodbox` artifact contract, the
  Haskell test and quality framework, the local edge foundations, the one-host config contract,
  and config-selected MetalLB BGP support.
- Phase 2 owns the gateway runtime, DNS inspection surface, the single-record Route 53 doctrine,
  and the TLA+ validation entrypoint; the Haskell gateway daemon itself is closed on the HTTP
  `/v1/state` payload, gateway status client path, interval validation, and the corresponding
  runtime-to-model notes.
- Phase 3 owns the chart platform, retained state model, supported public workload delivery, and
  the Percona-operator-backed Patroni PostgreSQL doctrine for Helm-managed workloads. It includes
  the JWT-protected API route, the Redis-backed WebSocket runtime, the shared public-workload
  runtime, multi-replica public workload scaling, the mixed-auth doctrine boundary between Envoy-
  managed browser auth and app-managed OIDC workloads, the explicit JWT carrier plus Keycloak
  JWKS-availability boundary, the shared-host Keycloak contract, real WebSocket upgrade handling,
  one-connection-per-pod lifetime, readiness-based drain, and path-routed Harbor plus MinIO admin
  delivery.
- Phase 4 owns Harbor-first lifecycle hardening, the narrowed Harbor-plus-storage-backend
  bootstrap exception, the public AWS-validation Pulumi surface, lifecycle-owned bootstrap DNS
  and ACME projection, Python removal, and the native-host-architecture container-build doctrine.
  Its lifecycle and retained AWS-validation cleanup shims are removed from the supported path.
- Phase 5 owns public-edge diagnostics and external proof on Route 53, Envoy Gateway, Gateway
  API, certificate readiness, and external browser validation. It includes API, WebSocket,
  Harbor, and MinIO route classification plus named external proofs for those workloads.
- Phase 6 owns the destructive clean-room rerun and zero-Python repository handoff criteria,
  closed through the aggregate rerun, postflight restore, `config show`, `config validate`,
  `host public-edge`, and the supported-path `example.com` search proof.
- Phase 7 owns interactive onboarding, IAM automation, quota management, and the elevated
  credential proof harness on one canonical public hostname with no placeholder-domain residue.

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
- `prodbox check-code` must fail on governed doctrine-alignment violations, not only on
  formatter, linter, build, or operator-binary sync failures.
- Every custom Dockerfile needing Haskell builds is single-stage from `ubuntu:24.04`, installs
  `ghcup` in-image, pins GHC `9.14.1`, and does not create symlinked Haskell tool shims. No
  supported browser-facing auth path depends on a repository-owned nginx auth-proxy image.
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
- Supported custom-image builds and Harbor publication use only the native architecture of the
  machine running `prodbox`: `amd64` hosts build `amd64` images, and `arm64` hosts build `arm64`
  images.
- Native `arm64` publication works on native `arm64` Docker daemons, including Apple Silicon with
  Colima. `docker buildx`, cross-arch emulation, and mixed-arch clusters are unsupported on the
  canonical lifecycle, gateway, and chart-delivery path.
- All supported Patroni use must flow through the cluster-wide Percona operator installed on the
  canonical lifecycle path.
- The self-managed public edge target uses MetalLB, Envoy Gateway, Gateway API, cert-manager, and
  Keycloak-backed edge auth rather than Traefik `Ingress` plus `vscode-nginx`.
- Supported public workloads and operational dashboards route only through Envoy on the shared
  hostname `test.resolvefintech.com`. The supported auth doctrine keeps the token carrier
  explicit across those paths: bearer tokens on JWT-protected routes, explicit browser return
  paths for proxy-auth surfaces, and workload-owned carrier or session state only where a route
  still needs direct-OIDC behavior behind the same host.
- Keycloak-backed public workloads must stay proxy-aware behind Envoy on the shared hostname,
  including issuer alignment, forwarded `X-Forwarded-*` header compatibility, and no supported
  public management or health route exposure unless a later doctrine revision makes that exposure
  explicit. Keycloak availability may gate login, refresh, and JWKS refresh, but the steady-state
  JWT hot path at Envoy must not depend on per-request Keycloak calls while cached signing keys
  and unexpired tokens suffice.
- The supported public-host doctrine uses one shared hostname, one DNS entry, and one
  certificate.
- Redis may appear only as repo-owned shared app state for supported realtime or rate-limit
  workloads; it is not part of Envoy JWT validation, and the current supported worktree does not
  yet ship a standalone external rate-limit service surface.
- Supported public API and admin routes must validate JWTs locally at Envoy from Keycloak issuer
  metadata and signing keys, with explicit bearer-token carriage, route-level RBAC, and
  JWKS-discovery ownership, rather than through per-request identity-provider lookups or Redis.
- Public listener TLS terminates at Envoy on the supported path. Backend TLS or mTLS is not part
  of the current chart-workload contract unless a later plan revision expands it explicitly.
- Supported WebSocket workloads authenticate at connection setup, keep reconnect-safe state
  outside the pod, keep each live upgraded connection pinned to one selected backend pod until
  disconnect, define token-expiry and authorization-change behavior explicitly, use readiness-
  based drain before pod exit, and leave per-message authorization to the application workload
  when message-level permissions are finer-grained than the edge can enforce.
- Every supported Helm-managed PostgreSQL deployment must be external, Percona-operator-backed
  Patroni HA with exactly three PostgreSQL replicas, synchronous replication, and no embedded
  chart-local PostgreSQL subchart.
- Pulumi remains the exclusive provisioner and destroyer for AWS test resources on the public
  `prodbox pulumi ...` surface, while bootstrap DNS reconcile and ACME `ClusterIssuer`
  projection remain lifecycle-owned in `src/Prodbox/CLI/Rke2.hs`.
- No supported Pulumi program or orchestration path may depend on Python.
- The only supported gateway steady state is inside the cluster as a Kubernetes workload.
- The gateway daemon, `prodbox gateway status`, and daemon config parsing must close on the
  implemented HTTP `/v1/state` surface, the Orders-backed interval-validation contract, and the
  current runtime-to-model notes in `documents/engineering/tla_modelling_assumptions.md`.
- The only supported DNS model is one explicit Route 53 record for `test.resolvefintech.com`;
  wildcard public DNS and per-service public hostnames are not part of the supported
  architecture.
- The supported public workload catalog includes the cluster-backed `vscode` stack, a
  JWT-protected API route, a WebSocket route, and path-routed operational dashboards; none may
  depend on app-local nginx auth proxies or dedicated public subdomains.
- `example.com` must be completely removed from the supported codebase, defaults, fixtures, and
  documented runtime contracts.
- Final handoff requires a destructive rerun from full local delete through final AWS teardown on
  the Haskell stack with no Python implementation dependency.
