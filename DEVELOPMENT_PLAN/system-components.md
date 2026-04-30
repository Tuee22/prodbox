# System Components

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [development_plan_standards.md](development_plan_standards.md), [00-overview.md](00-overview.md), [phase-1-runtime-cli-aws-foundations.md](phase-1-runtime-cli-aws-foundations.md), [phase-2-gateway-dns.md](phase-2-gateway-dns.md), [phase-3-chart-platform-vscode.md](phase-3-chart-platform-vscode.md), [phase-4-lifecycle-canonical-paths.md](phase-4-lifecycle-canonical-paths.md), [phase-7-aws-iam-quota-automation.md](phase-7-aws-iam-quota-automation.md)

> **Purpose**: Document the authoritative target component inventory for infrastructure, runtime
> control surfaces, validation surfaces, and state or authority boundaries in the Haskell rewrite.

The inventory documents the authoritative implemented Haskell-only architecture and the component
boundaries that the phase documents reference. When the cleanup ledger is non-empty,
[legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md) tracks unsupported residue
separately from this canonical inventory.

## Haskell-Only Architecture

| Surface | Owner | Paths |
|---------|-------|-------|
| CLI frontend and command surface | Haskell parser, native-only request ADT, and native command entrypoints for the full supported command matrix | `app/prodbox/Main.hs`, `src/Prodbox/CLI/Command.hs`, `src/Prodbox/CLI/Parser.hs`, `src/Prodbox/Native.hs`, `prodbox.cabal`, `cabal.project` |
| Configuration and settings | Haskell-owned Dhall-to-JSON decode bridge, repo-root config-path resolution, typed settings model, masked display, and validation over the operator-authored repo-root config | `src/Prodbox/Settings.hs`, `src/Prodbox/Repo.hs`, `prodbox-config.dhall`, `prodbox-config-types.dhall` |
| Settings and command runtime | Haskell build-support, effect, DAG, interpreter, prerequisite, result, subprocess, isolated AWS environment projection, and domain modules | `src/Prodbox/AwsEnvironment.hs`, `src/Prodbox/BuildSupport.hs`, `src/Prodbox/Effect.hs`, `src/Prodbox/EffectDAG.hs`, `src/Prodbox/EffectInterpreter.hs`, `src/Prodbox/Prerequisite.hs`, `src/Prodbox/Result.hs`, `src/Prodbox/Subprocess.hs`, `src/Prodbox/SupportedRuntime.hs`, `src/Prodbox/TestPlan.hs` |
| Host and Kubernetes helpers | Haskell host and k8s modules | `src/Prodbox/Host.hs`, `src/Prodbox/K8s.hs` |
| Container packaging and registry doctrine | Dockerfiles under `docker/`, Haskell-build containers that stay single-stage `ubuntu:24.04`, install `ghcup` in-image, pin GHC `9.14.1`, avoid symlinked Haskell tool shims, Harbor-first steady-state image sourcing with a Harbor-plus-storage-backend bootstrap exception only, ordered public-image candidate retry during Harbor mirror publish, per-platform dual-arch publication plus manifest reconcile, and mixed-arch cluster reconcile | `docker/`, `src/Prodbox/ContainerImage.hs`, `src/Prodbox/CLI/Rke2.hs`, `src/Prodbox/Lib/ChartPlatform.hs` |
| Pulumi orchestration and YAML stack programs | Haskell Pulumi orchestration over YAML Pulumi definitions for the public AWS validation stacks, including stack-config synchronization for AWS validation inputs, generated stack snapshots under `.prodbox-state/aws-test/` and `.prodbox-state/aws-eks-test/`, and the generated HA-RKE2 validation SSH key under `.prodbox-state/aws-test/`. Local-lifecycle bootstrap DNS reconcile and ACME `ClusterIssuer` projection stay outside the public `prodbox pulumi ...` stack-program surface, while legacy provider-config cleanup for retained validation stacks remains tracked in the Phase `4` ledger. | `src/Prodbox/CLI/Pulumi.hs`, `src/Prodbox/Infra/MinioBackend.hs`, `src/Prodbox/Infra/AwsTestStack.hs`, `src/Prodbox/Infra/AwsEksTestStack.hs`, `pulumi/aws-eks/Pulumi.yaml`, `pulumi/aws-eks/Main.yaml`, `pulumi/aws-test/Pulumi.yaml`, `pulumi/aws-test/Main.yaml`, generated state under `.prodbox-state/` |
| DNS inspection | Haskell DNS check module | `src/Prodbox/Dns.hs` |
| Gateway runtime | Haskell daemon runtime with HTTP `/v1/state` observability, heartbeat, in-memory ownership, DNS write loops, Orders-backed gateway-interval validation, HMAC signing, and single-stage `ubuntu:24.04` packaging with in-image `ghcup`, pinned GHC `9.14.1`, no symlinked Haskell tool shims, and an official AWS CLI bundle per target architecture. Config and Orders parsing still carry certificate and socket metadata, but the current closed runtime surface does not materialize peer transport from those fields. | `src/Prodbox/Gateway.hs`, `src/Prodbox/Gateway/Daemon.hs`, `src/Prodbox/Gateway/Types.hs`, `docker/gateway.Dockerfile` |
| Formal verification | Haskell TLA+ wrapper | `src/Prodbox/Tla.hs`, `documents/engineering/tla/` |
| Chart platform and retained state | Haskell chart registry, PostgreSQL platform constants, retained-storage reconciler, CLI runtime, the Percona-operator-backed application-database contract, the current Envoy-authenticated browser-delivery model for supported apps, and the future-workload boundary for JWT-only API or WebSocket surfaces | `src/Prodbox/CLI/Charts.hs`, `src/Prodbox/Lib/ChartPlatform.hs`, `src/Prodbox/Lib/Storage.hs`, `src/Prodbox/PostgresPlatform.hs`, `charts/`, plus generated retained non-PV state under `.prodbox-state/` |
| Public-edge diagnostics | Haskell host diagnostic | `src/Prodbox/Host.hs` |
| Onboarding and AWS administration | Haskell interactive onboarding plus AWS CLI subprocess orchestration for prompt-driven temporary elevated flows, with `aws_admin_for_test_simulation.*` reserved only for test-suite simulation of that ephemeral prompt input and supported AWS subprocess auth isolated from ambient host AWS state | `src/Prodbox/Aws.hs`, `src/Prodbox/AwsEnvironment.hs`, `src/Prodbox/CLI/Parser.hs`, `src/Prodbox/Native.hs` |
| Test harness and quality gate | Haskell build-support, governed-doctrine enforcement through `prodbox check-code`, aggregate suite ordering, supported-runtime bootstrap, and named real-world validation harness, including one shared suite-level AWS IAM harness that provisions temporary operational `aws.*` before aggregate AWS validation and clears those credentials again before suite return | `src/Prodbox/BuildSupport.hs`, `src/Prodbox/CheckCode.hs`, `src/Prodbox/TestPlan.hs`, `src/Prodbox/TestRunner.hs`, `src/Prodbox/TestValidation.hs`, `test/` |

## Infrastructure Layer

| Component | Technology | Deployment | Authority | Durable State |
|-----------|------------|------------|-----------|---------------|
| Supported host runtime | `Ubuntu 24.04 LTS` with systemd | Bare metal | `prodbox` supported-host gate | Host filesystem |
| Host build root | `.build/` | Repository worktree | Canonical `cabal build --builddir=.build exe:prodbox` plus copy to `.build/prodbox`; operator runs `./.build/prodbox` | Host filesystem |
| Container build root | `/opt/build` | Docker build stage | Dockerfiles under `docker/` | Container filesystem |
| Local Kubernetes substrate | RKE2 | Local host | `prodbox rke2 install|delete|status|start|stop|restart|logs`, including summary-oriented delete reporting | RKE2 data dirs and systemd units |
| Harbor-first registry pipeline | Harbor plus Docker CLI image reconcile, Harbor-plus-storage-backend public-registry bootstrap exception until Harbor is externally ready, post-bootstrap Harbor populate with ordered candidate retry on publish-time failure, and dual-arch publish | RKE2 workload plus host Docker runtime | `prodbox rke2 install` plus Harbor-first steady-state workload-image doctrine | Cluster resources, Harbor registry data, host Docker cache, and RKE2 registry config |
| AWS-backed EKS validation cluster | Amazon EKS | AWS | `prodbox pulumi eks-resources|eks-destroy --yes` plus `prodbox test integration aws-eks` | EKS resources in AWS |
| AWS-backed HA RKE2 test nodes | `Ubuntu 24.04 LTS` EC2 instances | AWS | `prodbox pulumi test-resources|test-destroy --yes` plus Haskell SSH orchestration | EC2, VPC, subnet, security-group, IAM, and Route 53 state |
| Pulumi test backend | MinIO | Local RKE2 workload | Local-cluster-first bootstrap plus Pulumi backend configuration, bounded backend login, and deleted-export-mount repair | S3-compatible objects in `prodbox-test-pulumi-backends` |
| Load balancer IPs | MetalLB on self-managed local clusters; current implementation closes on `IPAddressPool` plus `L2Advertisement` | RKE2 workload | Haskell lifecycle plus Gateway API edge doctrine | Cluster resources |
| Public edge controller | Envoy Gateway plus Kubernetes Gateway API, with current browser-facing auth enforced through `SecurityPolicy` and future JWT-only API validation governed at the same edge | RKE2 workload | Haskell lifecycle plus closed public-host doctrine, with pre-Envoy cleanup still tracked in the Phase `4` ledger | Cluster resources |
| TLS issuance | cert-manager plus ACME provider selected from config, with ZeroSSL EAB projection when configured | RKE2 workload | Haskell lifecycle plus chart runtime, including lifecycle-owned `ClusterIssuer` projection | Kubernetes secrets |
| DNS control plane | Route 53 hosted zone | AWS | Haskell AWS orchestration plus in-cluster gateway `dns_write_gate` | Route 53 |
| Gateway workload | Haskell gateway daemon | In-cluster Kubernetes workload | `prodbox charts deploy gateway` plus `prodbox gateway status` | Cluster resources, `gateway-aws-credentials`, and Route 53 |
| Cluster storage class | `manual` (`kubernetes.io/no-provisioner`) | RKE2 cluster | `prodbox rke2 install` | Cluster-scoped resource |
| Manual PV root | Configured host path, default `.data/` | Host filesystem | `prodbox-config.dhall` plus cluster and chart lifecycle commands | PV contents only |
| Retained repo-local state root | `.prodbox-state/` | Host filesystem | `prodbox charts`, `prodbox pulumi ...`, AWS validation helpers, and `prodbox rke2 delete --yes` preservation contract | Generated chart secrets, gateway event keys, AWS validation stack snapshots, and the HA-RKE2 validation SSH key |
| Chart platform | Helm plus Haskell orchestration | RKE2 workloads | `prodbox charts ...` | Cluster resources plus retained roots |
| Cluster-wide Patroni operator platform | Percona operator for PostgreSQL installed by the canonical Helm lifecycle | RKE2 workload | `prodbox rke2 install` plus Harbor-backed steady-state image sourcing, with incompatible pre-Percona operator cleanup still tracked in the Phase `4` ledger | Cluster resources |
| External application PostgreSQL HA | Percona-operator-backed Patroni PostgreSQL clusters with exactly three PostgreSQL replicas and synchronous replication, rendered from namespace-local application chart inputs and reconciled by the cluster-wide operator | RKE2 workloads | Haskell chart platform plus Harbor-backed steady-state image sourcing | Cluster resources plus retained roots |
| Namespace-local identity stack | `keycloak` on the dedicated public identity hostname | RKE2 workload | Haskell chart platform plus external Percona-operator-backed Patroni PostgreSQL dependency | Cluster resources plus retained roots |
| Namespace-local app stack | `vscode` behind an Envoy-authenticated dedicated public app route | RKE2 workload | Haskell chart platform | Cluster resources plus retained roots |
| Optional shared realtime state | Redis, only when a workload needs shared reconnect-safe or rate-limit state | Optional RKE2 workload | Future chart-platform workloads; not part of Envoy JWT validation and not a current shipped stack | Cluster resources plus app state |
| AWS admin credential isolation | Dhall config `aws_admin_for_test_simulation` section that stores only test-suite simulation of the ephemeral elevated prompt input; the native IAM validation harness is the only supported runtime consumer, and the shared named-and-aggregate IAM harness materializes operational `aws.*` from it only for the duration of a validation run | Repository config plus integration tests | Haskell config and IAM validation harness | Repository root |

## CLI and Runtime Layer

| Surface | Command | Purpose |
|---------|---------|---------|
| CLI frontend | `prodbox <command>` | Parse the closed command surface and dispatch directly to native Haskell commands with no legacy delegation shim |
| Config management | `prodbox config setup|show|validate` | Interactively author, display, and validate operator-authored repository-root Dhall configuration decoded directly into Haskell types, with temporary elevated AWS input provided by prompts on the supported public path |
| Host prerequisites and diagnostics | `prodbox host ensure-tools|info|check-ports|firewall` | Verify local tools and diagnose host-networking prerequisites |
| RKE2 lifecycle | `prodbox rke2 install|delete --yes|status|start|stop|restart|logs` | Install, inspect, control, and remove the local cluster with a concise delete summary, including the cluster-wide Percona operator lifecycle |
| Harbor reconcile and image population | `prodbox rke2 install` | Allow direct public pulls only for Harbor and Harbor's storage backend before Harbor is healthy and externally serving, require a stable `/readyz` plus `/v2/` external window, reconcile the `prodbox` project, and ensure required custom and public images are present in Harbor before later Helm deployments, retrying alternate configured public-image candidates when a preferred source fails during Harbor publication |
| Pulumi lifecycle | `prodbox pulumi eks-resources|eks-destroy --yes|test-resources|test-destroy --yes` | Manage the public AWS validation stacks only |
| Public-edge diagnostic | `prodbox host public-edge` | Classify Route 53, Gateway API, TLS, dedicated identity/app host routing, and external-reachability state |
| Gateway runtime | `prodbox gateway start|status|config-gen` | Start the in-pod gateway entrypoint, inspect gateway state over the governed HTTP `/v1/state` observability surface, and generate config |
| Chart runtime | `prodbox charts list|status|deploy|delete` | Manage the current chart platform, including Keycloak on the identity route and `vscode` on the Envoy-protected browser route, while leaving JWT-only API or WebSocket workloads as future additions |
| DNS check | `prodbox dns check` | Inspect DNS ownership state |
| Kubernetes utilities | `prodbox k8s health|wait|logs` | Inspect cluster readiness and collect infrastructure pod logs |
| Interactive onboarding | `prodbox config setup` | Guided Dhall authoring plus live AWS and operator prompts for one temporary elevated credential set |
| AWS IAM and quota management | `prodbox aws policy|setup|teardown|check-quotas|request-quotas` | Generate policies, manage IAM users, and manage AWS quotas through prompt-driven public admin flows |
| TLA+ validation | `prodbox tla-check` | Run formal verification |
| Test runner | `prodbox test ...` | Run named unit and integration suites on the Haskell stack, including the shared idempotent AWS IAM harness used by the named and aggregate IAM validation surfaces |
| Code quality | `prodbox check-code` | Run the required doctrine, formatting, lint, and type-check gate with governed doctrine-alignment enforcement |

## Validation Layer

| Surface | Canonical Validation |
|---------|----------------------|
| Build artifact contract | Runnable `./.build/prodbox`, produced by the canonical build-plus-copy flow; container build proof closes when the canonical Dockerfiles under `docker/` emit artifacts under `/opt/build` through in-image `ghcup`-managed GHC `9.14.1` with no symlinked Haskell tool shims |
| CLI and env contract | `prodbox test integration cli` and `prodbox test integration env` run built-frontend Haskell suites against the direct-Dhall config contract without recreating `prodbox-config.json` |
| Named validation harness | `prodbox test integration public-dns`, `dns-aws`, `aws-iam`, `gateway-daemon`, `gateway-pods`, `gateway-partition`, `lifecycle`, `pulumi`, `aws-eks`, `ha-rke2-aws`, `charts-platform`, `charts-storage`, and `charts-vscode` run executable native Haskell validation flows through `src/Prodbox/TestValidation.hs`, with the Phase `1/2` prerequisite DAG validating repository-root AWS credentials, Route 53 access, bounded MinIO-backed Pulumi login, and native IAM harness readiness before AWS-backed suites enter their validation bodies and without ambient AWS-auth fallback |
| Supported host gate and local cluster lifecycle | `prodbox test integration lifecycle`, fresh-host `prodbox rke2 install`, and destructive `prodbox rke2 delete --yes` proof with summary-oriented cleanup reporting |
| Harbor-first registry pipeline | `prodbox rke2 install`, bootstrap-source proof for the Harbor plus storage-backend direct-public exception before Harbor is externally ready, Harbor inventory proof for required images after bootstrap, stable `/readyz` plus `/v2/` proof before image writes, and dual-arch manifest proof for `amd64` and `arm64` |
| AWS Route 53 validation | `prodbox test integration dns-aws` |
| Pulumi-owned AWS lifecycle | `prodbox pulumi test-resources`, `prodbox pulumi test-destroy --yes`, `prodbox test integration pulumi` |
| AWS EKS validation | `prodbox pulumi eks-resources`, `prodbox pulumi eks-destroy --yes`, `prodbox test integration aws-eks` |
| AWS HA RKE2 validation | `prodbox test integration ha-rke2-aws` |
| Gateway runtime | `prodbox test integration gateway-daemon`, `prodbox test integration gateway-pods`, `prodbox test integration gateway-partition`, `prodbox tla-check` |
| Chart platform | `prodbox test integration charts-storage`, `prodbox test integration charts-platform`, `prodbox test integration charts-vscode`, plus manifest and lifecycle proof that supported Patroni use flows through the Percona operator-backed platform and that the current browser path is Envoy-authenticated |
| Public-host proof | `prodbox host public-edge`, `prodbox test integration public-dns` on the dedicated-hostname Gateway API target doctrine |
| Clean-room handoff | `prodbox rke2 delete --yes`, a rerun that starts and finishes with no supported-path `prodbox-config.json` artifact, `prodbox rke2 install`, `prodbox config show`, `prodbox config validate`, AWS-backed validation, `prodbox test all`, `prodbox host public-edge`, and a zero-Python repository file-search proof |
| AWS IAM lifecycle | `prodbox test integration aws-iam`, `prodbox test integration all`, and `prodbox test all` use one shared idempotent harness driven by the test-suite-only `aws_admin_for_test_simulation.*` section in `prodbox-config.dhall`; that harness deletes any pre-existing dedicated `prodbox` IAM user and keys before provisioning, uses any pre-existing `aws.*` only to discover and delete the IAM user associated with those credentials, and clears operational `aws.*` before returning |
| Static and doctrine gate | `prodbox check-code` |

## Authority and State Locations

| State Class | Authority | Durable Home | Notes |
|-------------|-----------|--------------|-------|
| Repository configuration | Operator-authored repository root | `prodbox-config.dhall` | Written by `prodbox config setup`, ignored from VCS, decoded directly into Haskell types, and temporarily materialized plus cleared by the shared IAM validation harness when it simulates the public interactive flow |
| Host build artifacts | Canonical `cabal build --builddir=.build exe:prodbox` plus copy to `.build/prodbox` | `.build/prodbox` | Operator-facing binary; run as `./.build/prodbox` |
| Container build artifacts | Dockerfiles under `docker/` | `/opt/build` | Canonical container build root |
| Harbor image state | Harbor plus Haskell lifecycle reconcile | Harbor project storage | Custom images and mirrored public images for both `amd64` and `arm64`, including the Envoy Gateway target edge image set |
| CLI and doctrine source | Repository worktree | `app/`, `src/`, `documents/`, `DEVELOPMENT_PLAN/` | Version-controlled source of truth |
| Manual PV content root | Host filesystem | Configured path, default `.data/<namespace>/<release>/<workload>/<ordinal>/<claim>` | PV contents only |
| Retained non-PV chart state | Chart platform helpers | `.prodbox-state/<namespace>/` | Generated secrets and gateway event keys |
| AWS validation local state | Haskell Pulumi orchestration and AWS validation helpers | Generated under `.prodbox-state/aws-test/` and `.prodbox-state/aws-eks-test/` | Pulumi stack snapshots plus the HA-RKE2 validation SSH key |
| Local RKE2 host state | Host lifecycle commands | RKE2 data dirs, kubeconfig files, systemd state | Deleted by `prodbox rke2 delete --yes` except retained roots, with expected-absence cleanup rendered as normal delete disposition |
| Remote EKS AWS test stack | Pulumi plus Haskell orchestration | EKS resources in AWS | Created and destroyed only through named `prodbox pulumi` surfaces |
| Remote HA RKE2 AWS test stack | Pulumi plus Haskell orchestration | EC2 and supporting AWS resources | Exactly three Ubuntu 24.04 EC2 instances in separate AZs |
| Cluster resource state | Kubernetes | RKE2 datastore | Managed through canonical Haskell CLI flows |
| DNS ownership | AWS Route 53 | Hosted zone records | Explicit per-FQDN identity and app records only; wildcard public DNS is unsupported |
| Pulumi backend state | Local-cluster MinIO | `prodbox-test-pulumi-backends` bucket | The local cluster must exist before remote AWS resources are created; backend validation recreates a deleted MinIO export host path and restarts `deployment/minio` before retrying login |
| Certificate material | Kubernetes | Secrets issued by cert-manager | ACME server URL comes from repository config, ZeroSSL EAB material is projected into `cert-manager/acme-eab-credentials` when configured, and the target public edge attaches those secrets to Gateway listeners |
| Gateway continuity state | Kubernetes plus retained chart state | Cluster resources plus `.prodbox-state/` | Used for ownership projection, DNS-write state, and event-key continuity |
| AWS admin credentials | `prodbox-config.dhall` `aws_admin_for_test_simulation` section | Operator-authored repository root | Test-suite-only stored simulation of the ephemeral elevated prompt input; the native IAM harness is the only supported runtime consumer, and the public command surface never reads it |

## Artifact Locations

| Type | Location | Purpose |
|------|----------|---------|
| Haskell application entrypoint | `app/prodbox/Main.hs` | Main CLI binary entrypoint |
| Haskell source modules | `src/Prodbox/` | CLI, infra, gateway, settings, and library implementation |
| Haskell tests | `test/` | Unit plus native CLI/env integration validation suites |
| Repository config artifacts | Operator-authored `prodbox-config.dhall` plus tracked `prodbox-config-types.dhall` | Haskell-owned config source and shared schema |
| Cabal package definition | `prodbox.cabal` | Build, test, and dependency definition |
| Cabal project definition | `cabal.project` | Repository-wide Cabal package-set definition |
| Host build root | `.build/` | Canonical host-side Haskell build artifacts; operator binary at `.build/prodbox` |
| Container build root | `/opt/build` | Canonical container-side Haskell build artifacts |
| Canonical custom Dockerfiles | `docker/` | Authoritative home for repository-owned container builds |
| Frontend container build | `docker/prodbox.Dockerfile` | Frontend image build owned by Phase `1`; single-stage `ubuntu:24.04` with in-image `ghcup`, pinned GHC `9.14.1`, and no symlinked Haskell tool shims |
| Gateway container build | `docker/gateway.Dockerfile` | Gateway image build owned by Phase `2`; single-stage `ubuntu:24.04` with in-image `ghcup`, pinned GHC `9.14.1`, no symlinked Haskell tool shims, and the official AWS CLI bundle keyed by `TARGETARCH` |
| Pulumi definitions | `pulumi/aws-eks/Pulumi.yaml`, `pulumi/aws-eks/Main.yaml`, `pulumi/aws-test/Pulumi.yaml`, `pulumi/aws-test/Main.yaml` | YAML Pulumi stacks (`runtime: yaml`) for the public AWS validation resources |
| Engineering doctrine | `documents/engineering/` | Architecture and operator docs |
| Development plan | `DEVELOPMENT_PLAN/` | Status, sequencing, and cleanup ownership |
| Manual PV content root | Configured path, default `.data/` | PV contents only |
| Retained repo-local state root | `.prodbox-state/` | Generated namespace-local chart state plus AWS validation snapshots and HA-RKE2 SSH key material |
| AWS validation local state | Generated under `.prodbox-state/aws-test/` and `.prodbox-state/aws-eks-test/` | Pulumi stack snapshots plus the HA-RKE2 validation SSH key |

## Related Documents

- [00-overview.md](00-overview.md)
- [phase-1-runtime-cli-aws-foundations.md](phase-1-runtime-cli-aws-foundations.md)
- [phase-2-gateway-dns.md](phase-2-gateway-dns.md)
- [phase-3-chart-platform-vscode.md](phase-3-chart-platform-vscode.md)
- [phase-4-lifecycle-canonical-paths.md](phase-4-lifecycle-canonical-paths.md)
- [phase-7-aws-iam-quota-automation.md](phase-7-aws-iam-quota-automation.md)
