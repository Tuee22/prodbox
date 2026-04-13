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
| Supported host runtime | `Ubuntu 24.04 LTS` with systemd | Bare metal | `prodbox` supported-host gate | Host filesystem |
| Kubernetes substrate | RKE2 | Local host | `prodbox rke2 install|delete|status|start|stop|restart|logs` | RKE2 data dirs and systemd units |
| Load balancer IPs | MetalLB | RKE2 workload | Pulumi plus cluster runtime | Cluster resources |
| Public edge ingress | Traefik | RKE2 workload | Pulumi plus cluster runtime | Cluster resources |
| Namespace-local auth proxy | `vscode-nginx` | RKE2 workload | Chart platform | Cluster resources |
| TLS issuance | cert-manager plus public ACME DNS-01 via Route 53 (current live server: ZeroSSL DV90 with EAB) | RKE2 workload | Pulumi plus cluster runtime | Kubernetes secrets |
| DNS control plane | Route 53 hosted zone | AWS | Pulumi bootstrap plus always-on in-cluster gateway `dns_write_gate` | Route 53 |
| Gateway mesh | Distributed gateway daemon | In-cluster Kubernetes workload under `prodbox charts` | `prodbox charts deploy gateway` plus `prodbox gateway status` | Cluster resources plus Route 53 |
| Cluster storage class | `manual` (`kubernetes.io/no-provisioner`) | RKE2 cluster | `prodbox rke2 install` | Cluster-scoped resource recreated at cluster install |
| Manual PV root | Configured host path (default `.data/`) | Host filesystem | `prodbox-config.dhall` plus cluster/chart lifecycle commands | PV contents only |
| Retained chart-state root | Repo-local `.prodbox-state/` | Host filesystem | `prodbox charts` helpers plus `prodbox rke2 delete --yes` preservation contract | Generated secrets and gateway event keys |
| Chart platform | Bespoke Helm/chart registry in repo | RKE2 workloads | `prodbox charts ...` | Configured manual PV root plus repo-local `.prodbox-state/` plus cluster resources |
| Namespace-local auth stack | `keycloak-postgres`, `keycloak` | RKE2 workloads | Chart platform | Configured manual PV root plus repo-local `.prodbox-state/` plus cluster resources |
| Namespace-local app stack | `vscode` | RKE2 workload | Chart platform | Configured manual PV root plus repo-local `.prodbox-state/` plus cluster resources |

## CLI and Runtime Layer

| Surface | Command | Purpose |
|---------|---------|---------|
| Config management | `prodbox config init|compile|show|validate` | Bootstrap, compile, auto-refresh when needed, display, and validate the Dhall-sourced configuration, including the manual PV host root |
| Host prerequisite flow | `prodbox host ensure-tools` | Verify required local tools |
| Public-edge diagnostic | `prodbox host public-edge` | Classify Route 53, ingress, certificate, and missing-edge state for the supported public host |
| RKE2 lifecycle | `prodbox rke2 install|delete --yes|status|start|stop|restart|logs` | Install, inspect, control, and remove the RKE2 cluster itself, including reboot-time systemd ownership and remnant-free delete except the configured manual PV root plus repo-local `.prodbox-state/` retained chart state |
| Pulumi lifecycle | `prodbox pulumi ...` | Manage MetalLB, Traefik, cert-manager, issuer bootstrap, and infrastructure previews |
| DNS check | `prodbox dns check` | Inspect current DNS ownership state |
| Kubernetes health | `prodbox k8s health|wait` | Inspect cluster readiness |
| Gateway runtime | `prodbox gateway start|status|config-gen` | `prodbox gateway start` is the in-pod entrypoint invoked by the gateway chart's container; `status` and `config-gen` support inspection and config authoring |
| Gateway steady state | `prodbox charts deploy gateway` plus `prodbox gateway status` | Deploy the in-cluster gateway workload and observe leader election and Route 53 write health |
| Chart runtime | `prodbox charts list|status|deploy|delete` | Manage the bespoke chart platform |
| TLA+ validation | `prodbox tla-check` | Run formal safety verification |
| Test runner | `prodbox test ...` | Run named unit and integration suites |
| Code quality | `prodbox check-code` | Run the required doctrine and static-analysis gate |

## Validation Layer

| Surface | Canonical Validation |
|---------|----------------------|
| CLI and env contract | `poetry run prodbox test integration cli`, `poetry run prodbox test integration env` |
| Supported host gate and cluster lifecycle | Fresh-host Ubuntu 24.04 proof for `poetry run prodbox rke2 install`, destructive proof for `poetry run prodbox rke2 delete --yes`, and `poetry run prodbox test integration lifecycle` |
| AWS foundation | `poetry run prodbox test integration aws-foundation`, `poetry run prodbox test integration aws-eks` |
| Route 53 and Pulumi | `poetry run prodbox test integration dns-aws`, `poetry run prodbox test integration pulumi` |
| Gateway runtime | `poetry run prodbox test integration gateway-daemon`, `poetry run prodbox test integration gateway-pods`, `poetry run prodbox test integration gateway-partition` |
| Chart platform | `poetry run prodbox test integration charts-storage`, `poetry run prodbox test integration charts-platform` |
| Lifecycle cleanup | `poetry run prodbox test integration lifecycle` |
| Public-host proof | `poetry run prodbox test integration charts-vscode`, `poetry run prodbox test integration public-dns` |
| Clean-room handoff | `poetry run prodbox rke2 delete --yes`, `poetry run prodbox rke2 install`, `poetry run prodbox test all`, `poetry run prodbox host public-edge` |
| Static and doctrine gate | `poetry run prodbox check-code` |

## Authority and State Locations

| State Class | Authority | Durable Home | Notes |
|-------------|-----------|--------------|-------|
| Repository configuration | Repository root | `prodbox-config.dhall` | Dhall config is the single source of truth; `prodbox config compile` is the explicit compile surface; canonical settings loads auto-compile `prodbox-config.json` idempotently when the compiled artifact is missing or stale; the config explicitly declares the manual PV host root and defaults it to `.data/`; subprocess environments are built from config only |
| CLI and doctrine source | Repository worktree | `src/`, `documents/`, `DEVELOPMENT_PLAN/` | Code and docs are version-controlled |
| Manual PV content root | Host filesystem | Configured path, default `.data/<namespace>/<release>/<workload>/<ordinal>/<claim>` | PV contents only; preserved across full cluster delete; deterministic rebinding depends on path stability |
| Retained non-PV chart state | Chart platform helpers | Repo-local `.prodbox-state/<namespace>/` | Generated secrets and gateway event keys; preserved across full cluster delete |
| RKE2 host state | Host lifecycle commands | RKE2 data dirs, kubeconfig files, systemd unit state | Deleted by `prodbox rke2 delete --yes` except for the configured manual PV root and repo-local `.prodbox-state/` retained chart-state root |
| Cluster resource state | Kubernetes | RKE2 datastore | Managed through canonical CLI flows |
| DNS ownership | AWS Route 53 | Hosted zone records | Pulumi bootstraps explicit per-FQDN records when enabled; the elected in-cluster gateway leader keeps their IPs current via `dns_write_gate` |
| AWS integration fixture state | AWS test account | Ephemeral Route 53, S3, VPC, EKS, and IAM resources | Each AWS-mutating fixture begins by sweeping any pre-existing fixture-owned AWS resources discoverable by canonical tags; those canonical tags are the stale-resource discovery contract, and no session sweep, standalone janitor CLI, or host cron job is part of the supported architecture |
| Certificate material | Kubernetes | Secrets issued by cert-manager | Canonical issuer object is `letsencrypt-http01`; the ACME server URL is configured in `prodbox-config.dhall`, and the current live target is ZeroSSL DV90 |
| Gateway runtime continuity | Kubernetes | Pod restart policy plus leader election and partition-tolerant quorum | Required to keep `dns_write_gate` active continuously across pod loss, node loss, and partition heals |
| Pulumi state | Pulumi backend | Stack state selected by repo config | Used only through canonical entrypoints |
| Host resolver state | Host operator | `/etc/hosts` plus local resolver cache | Authoritative public-host proof must not depend on a local override for `vscode.resolvefintech.com` |

## Artifact Locations

| Type | Location | Purpose |
|------|----------|---------|
| Source package | `src/prodbox/` | CLI, runtime, infra, and lint implementation |
| Unit tests | `tests/unit/` | Pure and interpreter-adjacent validation |
| Integration tests | `tests/integration/` | Real-system validation surfaces |
| Engineering doctrine | `documents/engineering/` | Stable architecture and operator docs |
| Development plan | `DEVELOPMENT_PLAN/` | Status, blockers, sequencing, and cleanup ownership |
| Manual PV content root | Configured path, default `.data/` | PV contents only; not deleted by full cluster delete |
| Retained chart-state root | `.prodbox-state/` | Generated secrets and gateway event keys preserved across full cluster delete |

## Related Documents

- [00-overview.md](00-overview.md)
- [phase-1-runtime-cli-aws-foundations.md](phase-1-runtime-cli-aws-foundations.md)
- [phase-2-gateway-dns.md](phase-2-gateway-dns.md)
- [phase-3-chart-platform-vscode.md](phase-3-chart-platform-vscode.md)
- [phase-4-lifecycle-canonical-paths.md](phase-4-lifecycle-canonical-paths.md)
- [../documents/engineering/cli_command_surface.md](../documents/engineering/cli_command_surface.md)
- [../documents/engineering/storage_lifecycle_doctrine.md](../documents/engineering/storage_lifecycle_doctrine.md)
- [../documents/engineering/distributed_gateway_architecture.md](../documents/engineering/distributed_gateway_architecture.md)
