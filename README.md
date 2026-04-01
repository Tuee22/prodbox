# Prodbox

**Status**: Reference only
**Supersedes**: N/A
**Referenced by**: CLAUDE.md, AGENTS.md

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
- **Route 53** - DNS management with dynamic DNS updates

Doctrine highlights:
- Exactly one prodbox instance per Linux machine (derived from `/etc/machine-id`).
- prodbox-created Kubernetes objects are tagged with `prodbox.io/id=<prodbox-id>`.
- Storage lifecycle preserves retained `StorageClass`/`PV`/`PVC` across cleanup for deterministic rebind.

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

All repo-managed configuration is via environment variables, but AWS authentication is not. `prodbox` uses the same ambient host auth state as the system-level `aws` CLI and rejects AWS auth env vars outright.

Authenticate the system-level AWS CLI on the host outside the repository, then run `prodbox` without exporting AWS auth env vars. The canonical storage and test-harness rules live in [AWS Integration Environment Doctrine](documents/engineering/aws_integration_environment_doctrine.md#2-authentication-source-and-storage-rules).

Required environment variables:

| Variable | Description |
|----------|-------------|
| `ROUTE53_ZONE_ID` | Route 53 hosted zone ID |
| `ACME_EMAIL` | Email for Let's Encrypt registration |

Optional (with defaults):

| Variable | Default | Description |
|----------|---------|-------------|
| `AWS_REGION` | `us-east-1` | AWS region |
| `DEMO_FQDN` | `demo.example.com` | Domain name |
| `DEMO_TTL` | `60` | DNS record TTL in seconds |
| `METALLB_POOL` | `192.168.1.240-192.168.1.250` | MetalLB IP range |
| `INGRESS_LB_IP` | `192.168.1.240` | Traefik LoadBalancer IP |
| `KUBECONFIG` | `~/.kube/config` | Path to kubeconfig |
| `ACME_SERVER` | Let's Encrypt production | ACME server URL |
| `PULUMI_STACK` | `home` | Default Pulumi stack name |
| `BOOTSTRAP_PUBLIC_IP_OVERRIDE` | unset | Bootstrap-only DNS A-record IP override when public IP lookup is unavailable |

Forbidden AWS auth environment variables include:
- `AWS_ACCESS_KEY_ID`
- `AWS_SECRET_ACCESS_KEY`
- `AWS_SESSION_TOKEN`
- `AWS_PROFILE`
- `AWS_SHARED_CREDENTIALS_FILE`
- `AWS_CONFIG_FILE`

Validate your configuration:

```bash
prodbox env validate
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

# Update DNS with current public IP
prodbox dns update

# Install systemd timer for automatic DDNS
prodbox dns ensure-timer
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

### Destroy Infrastructure

```bash
# Destroy all resources
prodbox pulumi destroy

# Idempotently remove all prodbox-annotated Kubernetes objects
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
poetry run daemon --config <path>
docker build -f docker/gateway.Dockerfile -t prodbox-gateway .
```

Gateway container build doctrine (explicit Poetry bootstrap, mirrored `.dockerignore`,
and container-local `poetry.toml` override) is defined in
[Local Registry Pipeline](documents/engineering/local_registry_pipeline.md#6-gateway-container-build-doctrine).

Testing note:
- `poetry run prodbox test all` runs unit + integration tests and fails fast when integration prerequisites are missing.
- Use `poetry run prodbox test unit` for unit-only environments.
- Integration-selected runs enforce `rke2 ensure` as a runbook gate before pytest starts.
- The phase-two pytest timeout budget is 240 minutes.
- Real shared-account AWS foundation validation uses `poetry run prodbox test integration aws-foundation` and exercises tagged delegated Route 53 child zones, S3 buckets, EC2/VPC resources, and janitor-style expired-resource cleanup.
- Real EKS validation uses `poetry run prodbox test integration aws-eks` and exercises a tagged fixture-owned EKS control plane plus tagged IAM/VPC dependencies.
- Real AWS DNS integration uses `poetry run prodbox test integration dns-aws` and requires a host-authenticated system `aws` CLI plus fixture-owned ephemeral Route 53 hosted zones via AWS CLI.
- Real Pulumi validation uses `poetry run prodbox test integration pulumi`, a local Pulumi backend, and a fixture-owned Route 53 hosted zone to exercise `stack-init`, `preview`, `up`, and `destroy` against isolated test state.

### Project Structure

```
prodbox/
├── src/prodbox/
│   ├── cli/         # Click CLI commands
│   ├── lib/         # Shared utilities
│   ├── infra/       # Pulumi infrastructure
│   └── settings.py  # Pydantic configuration
├── scripts/         # Systemd units
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

Automatic TLS certificate management using Let's Encrypt with DNS-01 validation via Route 53.

### Route 53

DNS management with:
- Pulumi-managed record existence
- DDNS updater for dynamic IP changes
- 60-second TTL for fast failover

## Documentation


### Engineering Documentation

Architecture and design documentation lives in `documents/engineering/`:

| Document | Purpose |
|----------|---------|
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

## License

MIT License - see [LICENSE](LICENSE) for details.
