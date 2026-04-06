# File: DEVELOPMENT_PLAN/system-components.md
# System Components

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [development_plan_standards.md](development_plan_standards.md), [00-overview.md](00-overview.md)

> **Purpose**: Document the authoritative component inventory for infrastructure, runtime control
> surfaces, validation surfaces, and state/authority boundaries.

## Infrastructure Layer

| Component | Technology | Deployment | Authority | Durable State |
|-----------|------------|------------|-----------|---------------|
| Host runtime | Linux host with systemd | Bare metal | Host operator | Host filesystem |
| Kubernetes substrate | RKE2 | Local host | `prodbox rke2 ...` | RKE2 data dirs |
| Load balancer IPs | MetalLB | RKE2 workload | Pulumi plus cluster runtime | Cluster resources |
| Ingress | Traefik | RKE2 workload | Pulumi plus cluster runtime | Cluster resources |
| TLS issuance | cert-manager plus Let's Encrypt HTTP-01 | RKE2 workload | Pulumi plus cluster runtime | Kubernetes secrets |
| DNS control plane | Route 53 hosted zone | AWS | Pulumi plus gateway `dns_write_gate` | Route 53 |
| Gateway mesh | Distributed gateway daemon | Host processes or pods | `prodbox gateway ...` | Runtime config plus cluster state |
| Chart platform | Bespoke Helm/chart registry in repo | RKE2 workloads | `prodbox charts ...` | `.data/` retained storage |
| Namespace-local auth stack | `keycloak-postgres`, `keycloak` | RKE2 workloads | Chart platform | `.data/` plus cluster resources |
| Namespace-local app stack | `vscode` | RKE2 workload | Chart platform | `.data/` plus cluster resources |

## CLI and Runtime Layer

| Surface | Command | Purpose |
|---------|---------|---------|
| Config validation | `prodbox env validate` | Validate required repository-root settings |
| Host prerequisite flow | `prodbox host ensure-tools` | Verify required local tools |
| RKE2 lifecycle | `prodbox rke2 ensure|status|cleanup --yes` | Provision, inspect, and clean cluster state |
| Pulumi lifecycle | `prodbox pulumi ...` | Manage infrastructure bootstrap and previews |
| DNS check | `prodbox dns check` | Inspect current DNS ownership state |
| Kubernetes health | `prodbox k8s health|wait` | Inspect cluster readiness |
| Gateway runtime | `prodbox gateway start|status|config-gen` | Manage the distributed gateway |
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
| Repository configuration | Repository root | `.env` | Sole supported auth/config source |
| CLI and doctrine source | Repository worktree | `src/`, `documents/`, `DEVELOPMENT_PLAN/` | Code and docs are version-controlled |
| Retained chart storage | Host filesystem | `.data/<namespace>/<statefulset>/<ordinal>` | Rebinds deterministically after cleanup |
| Cluster resource state | Kubernetes | RKE2 datastore | Managed through canonical CLI flows |
| DNS ownership | AWS Route 53 | Hosted zone records | Pulumi bootstrap plus gateway updates |
| Certificate material | Kubernetes | Secrets issued by cert-manager | Canonical issuer is `letsencrypt-http01` |
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
- [../documents/engineering/cli_command_surface.md](../documents/engineering/cli_command_surface.md)
- [../documents/engineering/storage_lifecycle_doctrine.md](../documents/engineering/storage_lifecycle_doctrine.md)
- [../documents/engineering/distributed_gateway_architecture.md](../documents/engineering/distributed_gateway_architecture.md)
