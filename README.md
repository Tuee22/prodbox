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
- **MetalLB** - LoadBalancer IP assignment using Layer 2 (ARP)
- **Traefik** - Ingress controller for HTTP/HTTPS traffic
- **cert-manager** - Automatic TLS certificates via Let's Encrypt
- **Route 53** - DNS management with dynamic DNS updates

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
- kubectl, helm, pulumi CLI tools
- AWS account with Route 53 hosted zone

### Install

```bash
# Clone the repository
git clone https://github.com/Tuee22/prodbox.git
cd prodbox

# Create virtual environment
python -m venv .venv
source .venv/bin/activate

# Install with dev dependencies
pip install -e ".[dev]"

# Verify installation
prodbox --version
```

## Configuration

All configuration is via environment variables. Create a `.env` file:

```bash
# Copy the example
cp .env.example .env

# Edit with your values
vim .env
```

Required environment variables:

| Variable | Description |
|----------|-------------|
| `AWS_ACCESS_KEY_ID` | AWS access key for Route 53 |
| `AWS_SECRET_ACCESS_KEY` | AWS secret key |
| `ROUTE53_ZONE_ID` | Route 53 hosted zone ID |
| `ACME_EMAIL` | Email for Let's Encrypt registration |

Optional (with defaults):

| Variable | Default | Description |
|----------|---------|-------------|
| `AWS_REGION` | `us-east-1` | AWS region |
| `DEMO_FQDN` | `demo.example.com` | Domain name |
| `METALLB_POOL` | `192.168.1.240-192.168.1.250` | MetalLB IP range |
| `INGRESS_LB_IP` | `192.168.1.240` | Traefik LoadBalancer IP |
| `KUBECONFIG` | `~/.kube/config` | Path to kubeconfig |
| `ACME_SERVER` | Let's Encrypt production | ACME server URL |

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

### Deploy Infrastructure

```bash
# Initialize Pulumi stack (first time only)
prodbox pulumi stack-init

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

### Destroy Infrastructure

```bash
# Preview destruction
prodbox pulumi preview

# Destroy all resources
prodbox pulumi destroy

# Tear down RKE2 runtime without deleting host storage paths
prodbox rke2 cleanup --yes
```

## CLI Commands

```
prodbox
├── env
│   ├── show        # Display current configuration
│   ├── validate    # Validate configuration
│   └── template    # Print .env template
├── host
│   ├── ensure-tools  # Check required CLI tools
│   ├── check-ports   # Check if ports 80/443 are in use
│   ├── info          # Display host system information
│   └── firewall      # Check firewall status
├── rke2
│   ├── status    # Check RKE2 installation status
│   ├── ensure    # Idempotently provision/start local RKE2 runtime
│   ├── start     # Start RKE2 service
│   ├── stop      # Stop RKE2 service
│   ├── restart   # Restart RKE2 service
│   ├── cleanup   # Non-destructive teardown (preserves host storage paths)
│   └── logs      # Show RKE2 logs
├── pulumi
│   ├── up          # Apply infrastructure changes
│   ├── destroy     # Destroy infrastructure
│   ├── preview     # Preview changes
│   ├── refresh     # Refresh state
│   └── stack-init  # Initialize Pulumi stack
├── dns
│   ├── check         # Check current DNS record
│   ├── update        # Update DNS with public IP
│   └── ensure-timer  # Install DDNS systemd timer
└── k8s
    ├── health  # Check cluster health
    ├── wait    # Wait for deployments
    └── logs    # Show infrastructure logs
```

## Development

### Setup

```bash
# Install dev dependencies
pip install -e ".[dev]"

# Run tests
poetry run prodbox test

# Run tests with coverage
poetry run prodbox test --cov=prodbox

# Code quality checks (canonical)
poetry run prodbox check-code
```

### Entrypoint Policy

All tooling runs through CLI entrypoints defined in `pyproject.toml`. Direct
`poetry run <tool>` commands are blocked once `prodbox check-code` installs the
entrypoint guard.

Common commands:

```bash
poetry run prodbox test -m "not integration"
poetry run prodbox check-code
poetry run prodbox tla-check
poetry run daemon --config <path>
```

Testing note:
- `poetry run prodbox test` runs unit + integration tests and fails fast when integration prerequisites are missing.
- Use `poetry run prodbox test -m "not integration"` for unit-only environments.

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

- [PRODBOX_PLAN.md](PRODBOX_PLAN.md) - Comprehensive project plan, architecture, and roadmap

### Engineering Documentation

Architecture and design documentation lives in `documents/engineering/`:

| Document | Purpose |
|----------|---------|
| [documentation_standards.md](documents/documentation_standards.md) | Documentation writing standards |
| [effectful_dag_architecture.md](documents/engineering/effectful_dag_architecture.md) | Effect DAG system design |
| [prerequisite_doctrine.md](documents/engineering/prerequisite_doctrine.md) | Fail-fast prerequisite philosophy |
| [unit_testing_policy.md](documents/engineering/unit_testing_policy.md) | Interpreter-Only Mocking Doctrine |
| [dependency_management.md](documents/engineering/dependency_management.md) | Poetry dependency standards |
| [pure_fp_standards.md](documents/engineering/pure_fp_standards.md) | Pure FP coding standards |
| [refactoring_patterns.md](documents/engineering/refactoring_patterns.md) | Imperative to pure FP migration patterns |
| [distributed_gateway_architecture.md](documents/engineering/distributed_gateway_architecture.md) | P2P gateway design |

## License

MIT License - see [LICENSE](LICENSE) for details.
