# File: DEVELOPMENT_PLAN/system-components.md
# System Components

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [development_plan_standards.md](development_plan_standards.md), [00-overview.md](00-overview.md), [phase-1-runtime-cli-aws-foundations.md](phase-1-runtime-cli-aws-foundations.md), [phase-2-gateway-dns.md](phase-2-gateway-dns.md), [phase-3-chart-platform-vscode.md](phase-3-chart-platform-vscode.md), [phase-4-lifecycle-canonical-paths.md](phase-4-lifecycle-canonical-paths.md)

> **Purpose**: Document the authoritative component inventory for infrastructure, runtime control
> surfaces, validation surfaces, and state/authority boundaries.

## Infrastructure Layer

| Component | Technology | Deployment | Authority | Durable State |
|-----------|------------|------------|-----------|---------------|
| Host runtime | Linux host with systemd | Bare metal | Host operator | Host filesystem |
| Kubernetes substrate | RKE2 | Local host | `prodbox rke2 ...` | RKE2 data dirs |
| Load balancer IPs | MetalLB | RKE2 workload | Pulumi plus cluster runtime | Cluster resources |
| Public edge ingress | Traefik | RKE2 workload | Pulumi plus cluster runtime | Cluster resources |
| Namespace-local auth proxy | `vscode-nginx` | RKE2 workload | Chart platform | Cluster resources |
| TLS issuance | cert-manager plus Let's Encrypt HTTP-01 | RKE2 workload | Pulumi plus cluster runtime | Kubernetes secrets |
| DNS control plane | Route 53 hosted zone | AWS | Pulumi bootstrap plus always-on gateway `dns_write_gate` | Route 53 |
| Gateway mesh | Distributed gateway daemon | Supervised host service or pod | `prodbox gateway ...` plus steady-state supervisor | Runtime config plus cluster state |
| Cluster storage class | `manual` (`kubernetes.io/no-provisioner`) | RKE2 cluster | Chart platform and Pulumi infra | No durable state (cluster-scoped resource) |
| Chart platform | Bespoke Helm/chart registry in repo | RKE2 workloads | `prodbox charts ...` | `.data/` retained storage |
| Namespace-local auth stack | `keycloak-postgres`, `keycloak` | RKE2 workloads | Chart platform | `.data/` plus cluster resources |
| Namespace-local app stack | `vscode` | RKE2 workload | Chart platform | `.data/` plus cluster resources |

## CLI and Runtime Layer

| Surface | Command | Purpose |
|---------|---------|---------|
| Config management | `prodbox config init|compile|show|validate` | Bootstrap, compile, display, and validate the Dhall-sourced configuration |
| Host prerequisite flow | `prodbox host ensure-tools` | Verify required local tools |
| Public-edge diagnostic | `prodbox host public-edge` | Classify Route 53, ingress, and certificate state for the supported public host |
| RKE2 lifecycle | `prodbox rke2 ensure|status|cleanup --yes` | Provision, inspect, and clean cluster state |
| Pulumi lifecycle | `prodbox pulumi ...` | Manage infrastructure bootstrap and previews |
| DNS check | `prodbox dns check` | Inspect current DNS ownership state |
| Kubernetes health | `prodbox k8s health|wait` | Inspect cluster readiness |
| Gateway runtime | `prodbox gateway start|status|config-gen|install-service` | Manage the distributed gateway and install the canonical host supervision path |
| Gateway steady state | `prodbox gateway install-service <config.json>` plus supervised `prodbox gateway start <config.json>` | Keep gateway ownership and Route 53 writes continuously active |
| Chart runtime | `prodbox charts list|status|deploy|delete` | Manage the bespoke chart platform |
| TLA+ validation | `prodbox tla-check` | Run formal safety verification |
| Test runner | `prodbox test ...` | Run named unit and integration suites |
| Code quality | `prodbox check-code` | Run the required doctrine and static-analysis gate |

## Validation Layer

| Surface | Canonical Validation |
|---------|----------------------|
| CLI and env contract | `poetry run prodbox test integration cli`, `poetry run prodbox test integration env` |
| AWS foundation | `poetry run prodbox test integration aws-foundation`, `poetry run prodbox test integration aws-eks` |
| Route 53 and Pulumi | `poetry run prodbox test integration dns-aws`, `poetry run prodbox test integration pulumi` |
| Gateway runtime | `poetry run prodbox test integration gateway-daemon`, `poetry run prodbox test integration gateway-pods` |
| Chart platform | `poetry run prodbox test integration charts-storage`, `poetry run prodbox test integration charts-platform` |
| Lifecycle cleanup | `poetry run prodbox test integration lifecycle` |
| Public-host proof | `poetry run prodbox test integration charts-vscode`, `poetry run prodbox test integration public-dns` |
| Static and doctrine gate | `poetry run prodbox check-code` |

## Authority and State Locations

| State Class | Authority | Durable Home | Notes |
|-------------|-----------|--------------|-------|
| Repository configuration | Repository root | `prodbox-config.dhall` | Dhall config compiled to `prodbox-config.json` by `prodbox config compile`; cluster-internal secrets auto-generated in `.data/`; IP addressing auto-discovered; kubeconfig uses default `~/.kube/config`; subprocess environments built from config only |
| CLI and doctrine source | Repository worktree | `src/`, `documents/`, `DEVELOPMENT_PLAN/` | Code and docs are version-controlled |
| Retained chart storage | Host filesystem | `.data/<namespace>/<release>/<workload>/<ordinal>/<claim>` | 5-segment path adopted by Sprint 4.5; rebinds deterministically after cleanup |
| Cluster resource state | Kubernetes | RKE2 datastore | Managed through canonical CLI flows |
| DNS ownership | AWS Route 53 | Hosted zone records | Pulumi bootstraps explicit per-FQDN records when enabled; supervised gateway updates keep their IPs current |
| Certificate material | Kubernetes | Secrets issued by cert-manager | Canonical issuer is `letsencrypt-http01` |
| Gateway runtime continuity | Host service manager or Kubernetes | Service supervisor or pod restart policy | Required to keep `dns_write_gate` active continuously |
| Pulumi state | Pulumi backend | Stack state selected by repo config | Used only through canonical entrypoints |

## Artifact Locations

| Type | Location | Purpose |
|------|----------|---------|
| Source package | `src/prodbox/` | CLI, runtime, infra, and lint implementation |
| Unit tests | `tests/unit/` | Pure and interpreter-adjacent validation |
| Integration tests | `tests/integration/` | Real-system validation surfaces |
| Engineering doctrine | `documents/engineering/` | Stable architecture and operator docs |
| Development plan | `DEVELOPMENT_PLAN/` | Status, blockers, sequencing, and cleanup ownership |
| Retained runtime state | `.data/` | Durable chart and platform storage |

## Related Documents

- [00-overview.md](00-overview.md)
- [phase-1-runtime-cli-aws-foundations.md](phase-1-runtime-cli-aws-foundations.md)
- [phase-2-gateway-dns.md](phase-2-gateway-dns.md)
- [phase-3-chart-platform-vscode.md](phase-3-chart-platform-vscode.md)
- [phase-4-lifecycle-canonical-paths.md](phase-4-lifecycle-canonical-paths.md)
- [../documents/engineering/cli_command_surface.md](../documents/engineering/cli_command_surface.md)
- [../documents/engineering/storage_lifecycle_doctrine.md](../documents/engineering/storage_lifecycle_doctrine.md)
- [../documents/engineering/distributed_gateway_architecture.md](../documents/engineering/distributed_gateway_architecture.md)
