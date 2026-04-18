# System Components

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [development_plan_standards.md](development_plan_standards.md), [00-overview.md](00-overview.md), [phase-1-runtime-cli-aws-foundations.md](phase-1-runtime-cli-aws-foundations.md), [phase-2-gateway-dns.md](phase-2-gateway-dns.md), [phase-3-chart-platform-vscode.md](phase-3-chart-platform-vscode.md), [phase-4-lifecycle-canonical-paths.md](phase-4-lifecycle-canonical-paths.md), [phase-7-aws-iam-quota-automation.md](phase-7-aws-iam-quota-automation.md)

> **Purpose**: Document the authoritative target component inventory for infrastructure, runtime
> control surfaces, validation surfaces, and state or authority boundaries in the Haskell rewrite.

The inventory documents the Haskell-only architecture. All phases are now closed on their owned
runtime or zero-Python removal surfaces.

## Haskell-Only Architecture

| Surface | Owner | Paths |
|---------|-------|-------|
| CLI frontend and command surface | Haskell parser plus native command entrypoints for the full supported command matrix | `app/prodbox/Main.hs`, `src/Prodbox/CLI/Parser.hs`, `src/Prodbox/Native.hs`, `prodbox.cabal`, `cabal.project`, `Dockerfile` |
| Configuration and settings | Haskell Dhall decoder, typed settings model, masked display, and validation | `src/Prodbox/Settings.hs`, `prodbox-config.dhall`, `prodbox-config-types.dhall` |
| Settings and command runtime | Haskell effect, DAG, interpreter, prerequisite, result, subprocess, and domain modules | `src/Prodbox/Effect.hs`, `src/Prodbox/EffectDAG.hs`, `src/Prodbox/EffectInterpreter.hs`, `src/Prodbox/Prerequisite.hs`, `src/Prodbox/Result.hs`, `src/Prodbox/Subprocess.hs`, `src/Prodbox/SupportedRuntime.hs`, `src/Prodbox/TestPlan.hs` |
| Host and Kubernetes helpers | Haskell host and k8s modules | `src/Prodbox/Host.hs`, `src/Prodbox/K8s.hs` |
| Local lifecycle and registry pipeline | Haskell `rke2` lifecycle including Harbor/local-registry and MinIO baseline | `src/Prodbox/CLI/Rke2.hs` |
| Pulumi orchestration and YAML stack programs | Haskell Pulumi orchestration over YAML Pulumi definitions | `src/Prodbox/CLI/Pulumi.hs`, `src/Prodbox/Infra/MinioBackend.hs`, `src/Prodbox/Infra/AwsTestStack.hs`, `src/Prodbox/Infra/AwsEksTestStack.hs`, `Pulumi.yaml`, `pulumi/home/Main.yaml`, `pulumi/aws-eks/Main.yaml`, `pulumi/aws-test/Main.yaml` |
| DNS inspection | Haskell DNS check module | `src/Prodbox/Dns.hs` |
| Gateway runtime | Haskell daemon runtime with heartbeat, ownership, DNS write loops, REST server, HMAC signing | `src/Prodbox/Gateway.hs`, `src/Prodbox/Gateway/Daemon.hs`, `src/Prodbox/Gateway/Types.hs`, `docker/gateway.Dockerfile` |
| Formal verification | Haskell TLA+ wrapper | `src/Prodbox/Tla.hs`, `documents/engineering/tla/` |
| Chart platform and retained state | Haskell chart registry, retained-storage reconciler, and CLI runtime | `src/Prodbox/CLI/Charts.hs`, `src/Prodbox/Lib/ChartPlatform.hs`, `src/Prodbox/Lib/Storage.hs`, `charts/`, `.prodbox-state/` |
| Public-edge diagnostics | Haskell host diagnostic | `src/Prodbox/Host.hs` |
| Onboarding and AWS administration | Haskell interactive onboarding plus AWS CLI subprocess orchestration | `src/Prodbox/Aws.hs`, `src/Prodbox/CLI/Parser.hs`, `src/Prodbox/Native.hs` |
| Test harness and quality gate | Haskell test runner, named real-world validation harness, and check-code entrypoints | `src/Prodbox/CheckCode.hs`, `src/Prodbox/TestRunner.hs`, `src/Prodbox/TestValidation.hs`, `test/` |

## Infrastructure Layer

| Component | Technology | Deployment | Authority | Durable State |
|-----------|------------|------------|-----------|---------------|
| Supported host runtime | `Ubuntu 24.04 LTS` with systemd | Bare metal | `prodbox` supported-host gate | Host filesystem |
| Host build root | `.build/` | Repository worktree | Canonical `cabal build --builddir=.build exe:prodbox` plus copy to `.build/prodbox`; operator runs `./.build/prodbox` | Host filesystem |
| Container build root | `/opt/build` | Docker build stage | Dockerfile | Container filesystem |
| Local Kubernetes substrate | RKE2 | Local host | `prodbox rke2 install|delete|status|start|stop|restart|logs` | RKE2 data dirs and systemd units |
| AWS-backed EKS validation cluster | Amazon EKS | AWS | `prodbox pulumi eks-resources|eks-destroy --yes` plus `prodbox test integration aws-eks` | EKS resources in AWS |
| AWS-backed HA RKE2 test nodes | `Ubuntu 24.04 LTS` EC2 instances | AWS | `prodbox pulumi test-resources|test-destroy --yes` plus Haskell SSH orchestration | EC2, VPC, subnet, security-group, IAM, and Route 53 state |
| Pulumi test backend | MinIO | Local RKE2 workload | Local-cluster-first bootstrap plus Pulumi backend configuration | S3-compatible objects in `prodbox-test-pulumi-backends` |
| Local registry and mirror pipeline | Harbor plus Docker CLI image reconcile | RKE2 workload plus host Docker runtime | `prodbox rke2 install` plus retained registry doctrine | Cluster resources, host Docker cache, and RKE2 registry config |
| Load balancer IPs | MetalLB | RKE2 workload | Pulumi plus cluster runtime | Cluster resources |
| Public edge ingress | Traefik | RKE2 workload | Pulumi plus cluster runtime | Cluster resources |
| TLS issuance | cert-manager plus ACME provider selected from config | RKE2 workload | Pulumi plus cluster runtime | Kubernetes secrets |
| DNS control plane | Route 53 hosted zone | AWS | Pulumi bootstrap plus in-cluster gateway `dns_write_gate` | Route 53 |
| Gateway mesh | Haskell distributed gateway daemon | In-cluster Kubernetes workload | `prodbox charts deploy gateway` plus `prodbox gateway status` | Cluster resources plus Route 53 |
| Cluster storage class | `manual` (`kubernetes.io/no-provisioner`) | RKE2 cluster | `prodbox rke2 install` | Cluster-scoped resource |
| Manual PV root | Configured host path, default `.data/` | Host filesystem | `prodbox-config.dhall` plus cluster and chart lifecycle commands | PV contents only |
| Retained chart-state root | `.prodbox-state/` | Host filesystem | `prodbox charts` helpers plus `prodbox rke2 delete --yes` preservation contract | Generated secrets and gateway event keys |
| Chart platform | Helm plus Haskell orchestration | RKE2 workloads | `prodbox charts ...` | Cluster resources plus retained roots |
| Namespace-local auth stack | `keycloak-postgres`, `keycloak`, `vscode-nginx` | RKE2 workloads | Haskell chart platform | Cluster resources plus retained roots |
| Namespace-local app stack | `vscode` | RKE2 workload | Haskell chart platform | Cluster resources plus retained roots |
| AWS admin credential isolation | Dhall config `aws_admin` section | Repository config plus integration tests | Haskell config and AWS admin helpers | Repository root |

## CLI and Runtime Layer

| Surface | Command | Purpose |
|---------|---------|---------|
| Config management | `prodbox config setup|show|validate` | Interactively author, display, and validate repository-root Dhall configuration decoded directly into Haskell types |
| Host prerequisites and diagnostics | `prodbox host ensure-tools|info|check-ports|firewall` | Verify local tools and diagnose host-networking prerequisites |
| RKE2 lifecycle | `prodbox rke2 install|delete --yes|status|start|stop|restart|logs` | Install, inspect, control, and remove the local cluster |
| Pulumi lifecycle | `prodbox pulumi up|destroy|preview|refresh|stack-init|eks-resources|eks-destroy --yes|test-resources|test-destroy --yes` | Manage local-cluster infrastructure and AWS validation stacks |
| Public-edge diagnostic | `prodbox host public-edge` | Classify Route 53, ingress, TLS, and external-reachability state |
| Gateway runtime | `prodbox gateway start|status|config-gen` | Start the in-pod gateway entrypoint, inspect gateway state, and generate config |
| Chart runtime | `prodbox charts list|status|deploy|delete` | Manage the chart platform and app stacks |
| DNS check | `prodbox dns check` | Inspect DNS ownership state |
| Kubernetes utilities | `prodbox k8s health|wait|logs` | Inspect cluster readiness and collect infrastructure pod logs |
| Interactive onboarding | `prodbox config setup` | Guided Dhall authoring plus live AWS and operator prompts |
| AWS IAM and quota management | `prodbox aws policy|setup|teardown|check-quotas|request-quotas` | Generate policies, manage IAM users, and manage AWS quotas |
| TLA+ validation | `prodbox tla-check` | Run formal verification |
| Test runner | `prodbox test ...` | Run named unit and integration suites on the Haskell stack |
| Code quality | `prodbox check-code` | Run the required doctrine, formatting, lint, and type-check gate |

## Validation Layer

| Surface | Canonical Validation |
|---------|----------------------|
| Build artifact contract | Runnable `./.build/prodbox`, produced by the canonical build-plus-copy flow; Dockerfile build proof still shows artifacts under `/opt/build` |
| CLI and env contract | `prodbox test integration cli` and `prodbox test integration env` run built-frontend Haskell suites against the direct-Dhall config contract without recreating `prodbox-config.json` |
| Named validation harness | `prodbox test integration public-dns`, `aws-iam`, `gateway-daemon`, `gateway-pods`, `gateway-partition`, `lifecycle`, `pulumi`, `aws-eks`, `ha-rke2-aws`, `charts-platform`, `charts-storage`, and `charts-vscode` run executable native Haskell validation flows through `src/Prodbox/TestValidation.hs` |
| Supported host gate and local cluster lifecycle | `prodbox test integration lifecycle`, fresh-host `prodbox rke2 install`, and destructive `prodbox rke2 delete --yes` proof |
| Local registry pipeline | `prodbox rke2 install`, `prodbox test integration gateway-pods` |
| AWS Route 53 validation | `prodbox test integration dns-aws` |
| Pulumi-owned AWS lifecycle | `prodbox pulumi test-resources`, `prodbox pulumi test-destroy --yes`, `prodbox test integration pulumi` |
| AWS EKS validation | `prodbox pulumi eks-resources`, `prodbox pulumi eks-destroy --yes`, `prodbox test integration aws-eks` |
| AWS HA RKE2 validation | `prodbox test integration ha-rke2-aws` |
| Gateway runtime | `prodbox test integration gateway-daemon`, `prodbox test integration gateway-pods`, `prodbox test integration gateway-partition`, `prodbox tla-check` |
| Chart platform | `prodbox test integration charts-storage`, `prodbox test integration charts-platform`, `prodbox test integration charts-vscode` |
| Public-host proof | `prodbox host public-edge`, `prodbox test integration public-dns` |
| Clean-room handoff | `prodbox rke2 delete --yes`, a rerun that starts and finishes with no supported-path `prodbox-config.json` artifact, `prodbox rke2 install`, `prodbox config show`, `prodbox config validate`, AWS-backed validation, `prodbox test all`, `prodbox host public-edge`, and a zero-Python repository file-search proof |
| AWS IAM lifecycle | `prodbox test integration aws-iam` |
| Static and doctrine gate | `prodbox check-code` |

## Authority and State Locations

| State Class | Authority | Durable Home | Notes |
|-------------|-----------|--------------|-------|
| Repository configuration | Repository root | `prodbox-config.dhall` | Single configuration source decoded directly into Haskell types |
| Host build artifacts | Canonical `cabal build --builddir=.build exe:prodbox` plus copy to `.build/prodbox` | `.build/prodbox` | Operator-facing binary; run as `./.build/prodbox` |
| Container build artifacts | Dockerfile | `/opt/build` | Canonical container build root |
| CLI and doctrine source | Repository worktree | `app/`, `src/`, `documents/`, `DEVELOPMENT_PLAN/` | Version-controlled source of truth |
| Manual PV content root | Host filesystem | Configured path, default `.data/<namespace>/<release>/<workload>/<ordinal>/<claim>` | PV contents only |
| Retained non-PV chart state | Chart platform helpers | `.prodbox-state/<namespace>/` | Generated secrets and gateway event keys |
| Local RKE2 host state | Host lifecycle commands | RKE2 data dirs, kubeconfig files, systemd state | Deleted by `prodbox rke2 delete --yes` except retained roots |
| Remote EKS AWS test stack | Pulumi plus Haskell orchestration | EKS resources in AWS | Created and destroyed only through named `prodbox pulumi` surfaces |
| Remote HA RKE2 AWS test stack | Pulumi plus Haskell orchestration | EC2 and supporting AWS resources | Exactly three Ubuntu 24.04 EC2 instances in separate AZs |
| Cluster resource state | Kubernetes | RKE2 datastore | Managed through canonical Haskell CLI flows |
| DNS ownership | AWS Route 53 | Hosted zone records | Explicit per-FQDN records only |
| Pulumi backend state | Local-cluster MinIO | `prodbox-test-pulumi-backends` bucket | The local cluster must exist before remote AWS resources are created |
| Certificate material | Kubernetes | Secrets issued by cert-manager | ACME server URL comes from repository config |
| Gateway continuity state | Kubernetes plus retained chart state | Cluster resources plus `.prodbox-state/` | Used for leader election and event-key continuity |
| AWS admin credentials | `prodbox-config.dhall` `aws_admin` section | Repository root | Test-only elevated credentials |

## Artifact Locations

| Type | Location | Purpose |
|------|----------|---------|
| Haskell application entrypoint | `app/prodbox/Main.hs` | Main CLI binary entrypoint |
| Haskell source modules | `src/Prodbox/` | CLI, infra, gateway, settings, and library implementation |
| Haskell tests | `test/` | Unit plus native CLI/env integration validation suites |
| Repository config artifacts | `prodbox-config.dhall`, `prodbox-config-types.dhall` | Haskell-owned config source and shared schema |
| Cabal package definition | `prodbox.cabal` | Build, test, and dependency definition |
| Cabal project definition | `cabal.project` | Repository-wide Cabal package-set definition |
| Host build root | `.build/` | Canonical host-side Haskell build artifacts; operator binary at `.build/prodbox` |
| Container build root | `/opt/build` | Canonical container-side Haskell build artifacts |
| Root Haskell container build | `Dockerfile` | `/opt/build` Haskell container build path |
| Pulumi definitions | `Pulumi.yaml`, `pulumi/home/Main.yaml`, `pulumi/aws-eks/Main.yaml`, `pulumi/aws-test/Main.yaml` | YAML Pulumi stacks (`runtime: yaml`) |
| Gateway container build | `docker/gateway.Dockerfile` | Multi-stage Haskell gateway image build (`haskell:9.6.7` builder, `debian:bookworm-slim` runtime) |
| VS Code auth-proxy image build | `docker/nginx-oidc.Dockerfile` | Custom auth-proxy image build |
| Engineering doctrine | `documents/engineering/` | Architecture and operator docs |
| Development plan | `DEVELOPMENT_PLAN/` | Status, sequencing, and cleanup ownership |
| Manual PV content root | Configured path, default `.data/` | PV contents only |
| Retained chart-state root | `.prodbox-state/` | Generated secrets and gateway event keys |

## Related Documents

- [00-overview.md](00-overview.md)
- [phase-1-runtime-cli-aws-foundations.md](phase-1-runtime-cli-aws-foundations.md)
- [phase-2-gateway-dns.md](phase-2-gateway-dns.md)
- [phase-3-chart-platform-vscode.md](phase-3-chart-platform-vscode.md)
- [phase-4-lifecycle-canonical-paths.md](phase-4-lifecycle-canonical-paths.md)
- [phase-7-aws-iam-quota-automation.md](phase-7-aws-iam-quota-automation.md)
