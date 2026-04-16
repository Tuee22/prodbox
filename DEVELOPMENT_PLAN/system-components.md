# System Components

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [development_plan_standards.md](development_plan_standards.md), [00-overview.md](00-overview.md), [phase-1-runtime-cli-aws-foundations.md](phase-1-runtime-cli-aws-foundations.md), [phase-2-gateway-dns.md](phase-2-gateway-dns.md), [phase-3-chart-platform-vscode.md](phase-3-chart-platform-vscode.md), [phase-4-lifecycle-canonical-paths.md](phase-4-lifecycle-canonical-paths.md), [phase-7-aws-iam-quota-automation.md](phase-7-aws-iam-quota-automation.md)

> **Purpose**: Document the authoritative target component inventory for infrastructure, runtime
> control surfaces, validation surfaces, and state or authority boundaries in the Haskell rewrite.

## Infrastructure Layer

| Component | Technology | Deployment | Authority | Durable State |
|-----------|------------|------------|-----------|---------------|
| Supported host runtime | `Ubuntu 24.04 LTS` with systemd | Bare metal | `prodbox` supported-host gate | Host filesystem |
| Host build root | `.build/` | Repository worktree | `cabal.project` | Host filesystem |
| Container build root | `/opt/build` | Docker build stage | Dockerfile | Container filesystem |
| Local Kubernetes substrate | RKE2 | Local host | `prodbox rke2 install|delete|status|start|stop|restart|logs` | RKE2 data dirs and systemd units |
| AWS-backed EKS validation cluster | Amazon EKS | AWS | `prodbox pulumi eks-resources|eks-destroy --yes` plus `prodbox test integration aws-eks` | EKS resources in AWS |
| AWS-backed HA RKE2 test nodes | `Ubuntu 24.04 LTS` EC2 instances | AWS | `prodbox pulumi test-resources|test-destroy --yes` plus Haskell SSH orchestration | EC2, VPC, subnet, security-group, IAM, and Route 53 state |
| Pulumi test backend | MinIO | Local RKE2 workload | Local-cluster-first bootstrap plus Pulumi backend configuration | S3-compatible objects in `prodbox-test-pulumi-backends` |
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
| Config management | `prodbox config compile|setup|show|validate` | Compile, materialize, display, validate, and interactively author configuration |
| RKE2 lifecycle | `prodbox rke2 install|delete --yes|status|start|stop|restart|logs` | Install, inspect, control, and remove the local cluster |
| Pulumi lifecycle | `prodbox pulumi up|destroy|preview|refresh|stack-init|eks-resources|eks-destroy --yes|test-resources|test-destroy --yes` | Manage local-cluster infrastructure and AWS validation stacks |
| Host prerequisite flow | `prodbox host ensure-tools` | Verify local tools required by the supported path |
| Public-edge diagnostic | `prodbox host public-edge` | Classify Route 53, ingress, TLS, and external-reachability state |
| Gateway runtime | `prodbox gateway start|status|config-gen` | Start the in-pod gateway entrypoint, inspect gateway state, and generate config |
| Chart runtime | `prodbox charts list|status|deploy|delete` | Manage the chart platform and app stacks |
| DNS check | `prodbox dns check` | Inspect DNS ownership state |
| Kubernetes health | `prodbox k8s health|wait` | Inspect cluster readiness |
| Interactive onboarding | `prodbox config setup` | Guided Dhall authoring plus live AWS and operator prompts |
| AWS IAM and quota management | `prodbox aws policy|setup|teardown|check-quotas|request-quotas` | Generate policies, manage IAM users, and manage AWS quotas |
| TLA+ validation | `prodbox tla-check` | Run formal verification |
| Test runner | `prodbox test ...` | Run named unit and integration suites on the Haskell stack |
| Code quality | `prodbox check-code` | Run the required doctrine, formatting, lint, and type-check gate |

## Validation Layer

| Surface | Canonical Validation |
|---------|----------------------|
| Build artifact contract | Host build proof shows artifacts under `.build/`; Dockerfile build proof shows artifacts under `/opt/build` |
| CLI and env contract | `prodbox test integration cli`, `prodbox test integration env` |
| Supported host gate and local cluster lifecycle | `prodbox test integration lifecycle`, fresh-host `prodbox rke2 install`, and destructive `prodbox rke2 delete --yes` proof |
| AWS Route 53 validation | `prodbox test integration dns-aws` |
| Pulumi-owned AWS lifecycle | `prodbox pulumi test-resources`, `prodbox pulumi test-destroy --yes`, `prodbox test integration pulumi` |
| AWS EKS validation | `prodbox pulumi eks-resources`, `prodbox pulumi eks-destroy --yes`, `prodbox test integration aws-eks` |
| AWS HA RKE2 validation | `prodbox test integration ha-rke2-aws` |
| Gateway runtime | `prodbox test integration gateway-daemon`, `prodbox test integration gateway-pods`, `prodbox test integration gateway-partition`, `prodbox tla-check` |
| Chart platform | `prodbox test integration charts-storage`, `prodbox test integration charts-platform`, `prodbox test integration charts-vscode` |
| Public-host proof | `prodbox host public-edge`, `prodbox test integration public-dns` |
| Clean-room handoff | `prodbox rke2 delete --yes`, deletion of the materialized `prodbox-config.json` artifact, `prodbox rke2 install`, `prodbox config show`, `prodbox config validate`, AWS-backed validation, `prodbox test all`, `prodbox host public-edge`, and a zero-Python repository file-search proof |
| AWS IAM lifecycle | `prodbox test integration aws-iam` |
| Static and doctrine gate | `prodbox check-code` |

## Authority and State Locations

| State Class | Authority | Durable Home | Notes |
|-------------|-----------|--------------|-------|
| Repository configuration | Repository root | `prodbox-config.dhall` | Single configuration source; materialized JSON may exist when required by downstream tools |
| Host build artifacts | Cabal build configuration | `.build/` | Canonical host build root |
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
| Haskell tests | `test/` | Unit and integration validation |
| Cabal package definition | `prodbox.cabal` | Build, test, and dependency definition |
| Cabal project definition | `cabal.project` | Repository-wide build configuration including `.build/` ownership |
| Host build root | `.build/` | Canonical host-side Haskell build artifacts |
| Container build root | `/opt/build` | Canonical container-side Haskell build artifacts |
| Pulumi definitions | `pulumi/` | Non-Python Pulumi stacks and supporting assets |
| Engineering doctrine | `documents/engineering/` | Stable architecture and operator docs |
| Development plan | `DEVELOPMENT_PLAN/` | Status, blockers, sequencing, and cleanup ownership |
| Manual PV content root | Configured path, default `.data/` | PV contents only |
| Retained chart-state root | `.prodbox-state/` | Generated secrets and gateway event keys |

## Related Documents

- [00-overview.md](00-overview.md)
- [phase-1-runtime-cli-aws-foundations.md](phase-1-runtime-cli-aws-foundations.md)
- [phase-2-gateway-dns.md](phase-2-gateway-dns.md)
- [phase-3-chart-platform-vscode.md](phase-3-chart-platform-vscode.md)
- [phase-4-lifecycle-canonical-paths.md](phase-4-lifecycle-canonical-paths.md)
- [phase-7-aws-iam-quota-automation.md](phase-7-aws-iam-quota-automation.md)
