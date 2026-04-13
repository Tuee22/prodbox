# Prodbox

**Status**: Reference only
**Supersedes**: N/A
**Referenced by**: CLAUDE.md, AGENTS.md, DEVELOPMENT_PLAN/README.md

> **Purpose**: Project overview, installation guide, and documentation index for prodbox.

Home Kubernetes cluster management with Pulumi.

[![Python 3.12+](https://img.shields.io/badge/python-3.12+-blue.svg)](https://www.python.org/downloads/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

## Overview

Prodbox is a Python-native infrastructure-as-code project for managing a home Kubernetes cluster. It deploys and manages:

- **RKE2** - Kubernetes distribution lifecycle managed via eDAG (`ensure`/`cleanup`)
- **Harbor** - In-cluster local registry + Docker Hub mirror pipeline
- **MinIO** - In-cluster object storage on retained local PV/PVC storage
- **MetalLB** - LoadBalancer IP assignment using Layer 2 (ARP)
- **Traefik** - Ingress controller for HTTP/HTTPS traffic
- **cert-manager** - Automatic TLS certificates via Let's Encrypt
- **Route 53** - DNS record ownership via Pulumi bootstrap plus gateway writes
- **Bespoke Charts** - Namespace-local `keycloak-postgres`, `keycloak`, and `vscode` stacks with retained `.data/` storage

Doctrine highlights:
- Exactly one prodbox instance per Linux machine (derived from `/etc/machine-id`).
- prodbox-created Kubernetes objects are tagged with `prodbox.io/id=<prodbox-id>`.
- Storage lifecycle preserves retained `StorageClass`/`PV`/`PVC` across cleanup for deterministic rebind.
- The only supported `vscode` delivery path is the cluster-backed `prodbox charts` stack.

Implementation status, remaining work, and legacy-path removal are tracked in
[DEVELOPMENT_PLAN/README.md](./DEVELOPMENT_PLAN/README.md). Engineering docs under `documents/engineering/`
define stable doctrine and command contracts.

## Architecture

```
Internet → Router (80/443 port-forward) → MetalLB IP → Traefik → Services → Pods
                                                           ↓
                                                    cert-manager
                                                    (TLS certs)
```

### Network Design

- **Node IP**: Your server's LAN IP (e.g., `192.168.1.10`)
- **MetalLB Pool**: Dedicated IPs for LoadBalancer services (e.g., `192.168.1.240-192.168.1.250`)
- **Ingress LB IP**: Reserved IP for Traefik (e.g., `192.168.1.240`)

Router port forwarding:
- WAN:80 → MetalLB IP:80
- WAN:443 → MetalLB IP:443
- WAN:44444 → Node IP:22 (SSH)

## Installation

### Prerequisites

- Python 3.12+
- Linux host with systemd
- RKE2 binary and config already installed (`/usr/local/bin/rke2`, `/etc/rancher/rke2/config.yaml`)
- kubectl, helm, docker, ctr, sudo, pulumi CLI tools
- AWS account with Route 53 hosted zone

### Install

```bash
# Clone the repository
git clone https://github.com/Tuee22/prodbox.git
cd prodbox

# Install project and dev dependencies
poetry install

# Verify installation
poetry run prodbox --version
```

## Configuration

All configuration is authored in the repository-root `prodbox-config.dhall` (Dhall schema with
typed defaults), compiled to `prodbox-config.json` by `prodbox config compile`, and loaded into
a Pydantic `BaseModel` at runtime. Both files are gitignored. Cluster-internal secrets are
auto-generated at chart deploy time and stored in `.data/<namespace>/.secrets.json`. IP
addressing (MetalLB pool, ingress LB IP) is always auto-discovered from the host LAN.
Subprocess environments are built from explicit configuration only — no `os.environ` credentials
are inherited.

### Bootstrap

```bash
# One-time: bootstrap Dhall config from existing .env (if migrating)
prodbox config init

# Or manually create prodbox-config.dhall using the schema
# Then compile to JSON:
prodbox config compile
```

### Required config fields

| Config Path | Description |
|-------------|-------------|
| `aws.access_key_id` | AWS access key ID for Route 53 and AWS integration operations |
| `aws.secret_access_key` | AWS secret access key for Route 53 and AWS integration operations |
| `route53.zone_id` | Route 53 hosted zone ID |
| `acme.email` | Email for Let's Encrypt registration |

Required when using the chart platform and public `vscode` flow:

| Config Path | Description |
|-------------|-------------|
| `domain.vscode_fqdn` | Public FQDN for the namespace-local `vscode` and Keycloak ingress path |

Cluster-internal secrets (`KEYCLOAK_ADMIN_PASSWORD`, `KEYCLOAK_POSTGRES_PASSWORD`,
`KEYCLOAK_NGINX_CLIENT_SECRET`) are auto-generated at chart deploy time and stored in
`.data/<namespace>/.secrets.json`. They do not appear in the config file.

### Optional fields (with defaults)

| Config Path | Default | Description |
|-------------|---------|-------------|
| `aws.region` | `us-east-1` | AWS region |
| `aws.session_token` | `None` | Optional AWS session token |
| `domain.demo_fqdn` | `demo.example.com` | Domain name |
| `domain.demo_ttl` | `60` | DNS record TTL in seconds |
| `acme.server` | Let's Encrypt production | ACME server URL |
| `deployment.bootstrap_public_ip_override` | `None` | Bootstrap-only DNS A-record IP override |

### Auto-discovered (not in config)

| Setting | Source | Description |
|---------|--------|-------------|
| MetalLB pool | Host LAN auto-discovery | IP range for MetalLB LoadBalancer allocation |
| Ingress LB IP | Host LAN auto-discovery | Traefik LoadBalancer IP |
| Kubeconfig | `~/.kube/config` | Default kubeconfig path (always used) |
| Pulumi stack | Hardcoded `home` | Default Pulumi stack name |

Validate your configuration:

```bash
prodbox config validate
```

## Usage

### Check Prerequisites

```bash
# Verify required CLI tools
prodbox host ensure-tools

# Idempotently provision/start local RKE2 cluster runtime
prodbox rke2 ensure

# Check resulting RKE2 status
prodbox rke2 status
```

Prerequisite failure contract:
- Manual environment fixes are emitted once from the root-cause prerequisite under `Manual env changes needed`.
- Downstream propagated prerequisite failures intentionally do not add duplicate fix hints.

### Deploy Infrastructure

```bash
# Initialize Pulumi stack (first time only)
prodbox pulumi stack-init home

# Preview changes
prodbox pulumi preview

# Deploy infrastructure
prodbox pulumi up
```

### Manage DNS

```bash
# Check current DNS record
prodbox dns check
```

### Check Health

```bash
# Check cluster and component health
prodbox k8s health

# Wait for deployments to be ready
prodbox k8s wait
```

### Manage Bespoke Charts

```bash
# List all supported charts with install status
prodbox charts list

# Show detailed status for one chart
prodbox charts status vscode

# Deploy a root chart stack (keycloak-postgres → keycloak → vscode)
prodbox charts deploy vscode

# Delete a root chart stack (preserves .data/ host storage)
prodbox charts delete vscode
```

`vscode` is supported only through the cluster-backed chart stack; there is no separate
`docker/vscode-dev` delivery path.

### Destroy Infrastructure

```bash
# Destroy all resources
prodbox pulumi destroy

# Idempotently remove all prodbox-annotated Kubernetes objects via namespace-first cascade
prodbox rke2 cleanup --yes
```

## CLI Commands

The authoritative `prodbox` command matrix lives in [CLI Command Surface](documents/engineering/cli_command_surface.md). The CLI intentionally exposes named Click commands only; extra passthrough arguments are rejected at the CLI boundary.

## Development

### Setup

```bash
# Install dev dependencies
poetry install

# Run tests
poetry run prodbox test all

# Run tests with coverage
poetry run prodbox test all --coverage --cov-fail-under 100

# Code quality checks (canonical)
poetry run prodbox check-code
```

### Entrypoint Policy

All tooling runs through CLI entrypoints defined in `pyproject.toml`. Direct
`poetry run <tool>` commands are blocked once `prodbox check-code` installs the
entrypoint guard.

poetry run prodbox check-code is the required single entrypoint for doctrine enforcement in local development.

Development tooling policy:
- Do not use `.github/` workflows or CI automation for this project at this stage.
- Do not use git hooks (including pre-commit); run CLI entrypoints directly.
- See [Code Quality Doctrine](documents/engineering/code_quality.md#2a-development-tooling-policy).

Common commands:

```bash
poetry run prodbox test unit
poetry run prodbox check-code
poetry run prodbox tla-check
poetry run prodbox gateway start <path>
docker build -f docker/gateway.Dockerfile -t prodbox-gateway .
```

Gateway container build doctrine (explicit Poetry bootstrap, mirrored `.dockerignore`,
and container-local `poetry.toml` override) is defined in
[Local Registry Pipeline](documents/engineering/local_registry_pipeline.md#6-gateway-container-build-doctrine).

Testing note:
- `poetry run prodbox test all` runs unit + integration tests and fails fast when integration prerequisites are missing.
- Use `poetry run prodbox test unit` for unit-only environments.
- Cluster-backed integration suites enforce `rke2 ensure` as a runbook gate before pytest starts.
- `poetry run prodbox test integration charts-vscode` is an external public-host suite and does not require cluster gates or `rke2 ensure`.
- `poetry run prodbox test integration public-dns` is the external authoritative delegation proof for the hosted zone that owns `VSCODE_FQDN`; it does not require cluster gates or `rke2 ensure`.
- The phase-two pytest timeout budget is 240 minutes.
- Real shared-account AWS foundation validation uses `poetry run prodbox test integration aws-foundation` and exercises tagged delegated Route 53 child zones, S3 buckets, EC2/VPC resources, harness-owned preflight sweeping, and expired-resource cleanup.
- Real EKS validation uses `poetry run prodbox test integration aws-eks` and exercises a tagged fixture-owned EKS control plane plus tagged IAM/VPC dependencies.
- Real AWS DNS integration uses `poetry run prodbox test integration dns-aws` to validate the canonical gateway Route 53 write client against fixture-owned ephemeral hosted zones.
- Real public DNS delegation validation uses `poetry run prodbox test integration public-dns` to compare the public NS view with the canonical Route 53 hosted zone named by `ROUTE53_ZONE_ID`.
- Real Pulumi validation uses `poetry run prodbox test integration pulumi`, a local Pulumi backend, and a fixture-owned Route 53 hosted zone to exercise `stack-init`, `preview`, `up`, and `destroy` against isolated test state.

### Project Structure

```
prodbox/
├── src/prodbox/
│   ├── cli/         # Click CLI commands
│   ├── lib/         # Shared utilities
│   ├── infra/       # Pulumi infrastructure
│   └── settings.py  # Pydantic configuration
└── tests/           # Test suite
```

## Infrastructure Components

### MetalLB (v0.14.9)

Provides LoadBalancer functionality for bare-metal clusters using Layer 2 mode (ARP advertisement).

### Traefik (v32.0.0)

Ingress controller handling HTTP/HTTPS traffic routing. Configured with:
- LoadBalancer service with specific IP from MetalLB
- HTTP and HTTPS entrypoints exposed
- Prometheus metrics enabled

### cert-manager (v1.16.2)

Automatic TLS certificate management using Let's Encrypt with HTTP-01 validation via ingress.

### Route 53

DNS management with:
- Pulumi-managed record existence
- Gateway-owner Route 53 writes for dynamic IP changes
- 60-second TTL for fast failover

## Documentation

Current development sequencing and delivery status:

- [DEVELOPMENT_PLAN/README.md](DEVELOPMENT_PLAN/README.md) - single roadmap, completion tracker, and legacy-removal inventory

Canonical engineering documentation:

### Engineering Documentation

Architecture and design documentation lives in `documents/engineering/`:

| Document | Purpose |
|----------|---------|
| [README.md](documents/engineering/README.md) | Engineering documentation index |
| [documentation_standards.md](documents/documentation_standards.md) | Documentation writing standards |
| [effectful_dag_architecture.md](documents/engineering/effectful_dag_architecture.md) | Effect DAG system design |
| [effect_interpreter.md](documents/engineering/effect_interpreter.md) | Interpreter runtime contract |
| [prerequisite_doctrine.md](documents/engineering/prerequisite_doctrine.md) | Fail-fast prerequisite philosophy |
| [prerequisite_dag_system.md](documents/engineering/prerequisite_dag_system.md) | Prerequisite DAG expansion and runtime |
| [streaming_doctrine.md](documents/engineering/streaming_doctrine.md) | Streaming serialization doctrine |
| [unit_testing_policy.md](documents/engineering/unit_testing_policy.md) | Interpreter-Only Mocking Doctrine |
| [dependency_management.md](documents/engineering/dependency_management.md) | Poetry dependency standards |
| [pure_fp_standards.md](documents/engineering/pure_fp_standards.md) | Pure FP coding standards |
| [code_quality.md](documents/engineering/code_quality.md) | Guardrail and check-code doctrine |
| [refactoring_patterns.md](documents/engineering/refactoring_patterns.md) | Imperative to pure FP migration patterns |
| [distributed_gateway_architecture.md](documents/engineering/distributed_gateway_architecture.md) | P2P gateway design |
| [local_registry_pipeline.md](documents/engineering/local_registry_pipeline.md) | Harbor install + Docker build/push + mirror behavior |
| [storage_lifecycle_doctrine.md](documents/engineering/storage_lifecycle_doctrine.md) | Retained storage + deterministic PVC/PV rebinding doctrine |
| [helm_chart_platform_doctrine.md](documents/engineering/helm_chart_platform_doctrine.md) | Canonical chart-platform doctrine for `prodbox charts` |

## License

MIT License - see [LICENSE](LICENSE) for details.
