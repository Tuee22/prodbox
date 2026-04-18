# Prodbox

**Status**: Reference only
**Supersedes**: N/A
**Referenced by**: CLAUDE.md, AGENTS.md, DEVELOPMENT_PLAN/README.md

> **Purpose**: Project overview, installation guide, and documentation index for prodbox.

Home Kubernetes cluster management with Pulumi.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

## Overview

Prodbox is in an explicit rewrite state.

- The authoritative target architecture, sprint status, and cleanup ownership live in
  [DEVELOPMENT_PLAN/README.md](./DEVELOPMENT_PLAN/README.md).
- The current worktree implementation is mixed: a compiled Haskell frontend now lives
  under `app/`, `src/Prodbox/`, `test/`, `prodbox.cabal`, `cabal.project`, and `Dockerfile`;
  Haskell owns `config compile|show|validate`, `host ensure-tools|check-ports|info|firewall|public-edge`,
  `dns check`, `gateway status|config-gen`, `k8s health|wait|logs`, `check-code`, `tla-check`,
  and the public `test` entrypoint, including named-suite and aggregate-suite orchestration, while
  most product behavior still lives under `src/prodbox/` and `tests/`.
- The supported handoff target is a Haskell-owned `prodbox` binary with no supported-path Python
  implementation or Python toolchain ownership.

The current repository baseline deploys and manages:

- **RKE2** - Kubernetes distribution lifecycle managed via eDAG (`install`/`delete`)
- **Harbor** - In-cluster local registry + Docker Hub mirror pipeline
- **MinIO** - In-cluster object storage on retained local PV/PVC storage
- **MetalLB** - LoadBalancer IP assignment using Layer 2 (ARP)
- **Traefik** - Ingress controller for HTTP/HTTPS traffic
- **cert-manager** - Automatic TLS certificates via a configurable public ACME provider
- **Route 53** - DNS record ownership via Pulumi bootstrap plus gateway writes
- **Interactive Onboarding** - `prodbox config setup` for account guidance, ACME selection, and config generation
- **AWS IAM Automation** - `prodbox aws ...` for policy generation, IAM lifecycle, and service quota management
- **AWS Validation Stacks** - `prodbox pulumi eks-resources|eks-destroy --yes|test-resources|test-destroy --yes` for the EKS and HA RKE2 AWS-backed validation paths
- **Bespoke Charts** - Namespace-local `keycloak-postgres`, `keycloak`, and `vscode` stacks with retained `.data/` PV storage plus `.prodbox-state/` chart state

Doctrine highlights:
- Exactly one prodbox instance per Linux machine (derived from `/etc/machine-id`).
- prodbox-created Kubernetes objects are tagged with `prodbox.io/id=<prodbox-id>`.
- Storage lifecycle preserves retained host state across delete/reinstall for deterministic rebind.
- The only supported `vscode` delivery path is the cluster-backed `prodbox charts` stack.
- The current worktree onboarding path remains `poetry run prodbox config setup`, but the
  public Phase 7 onboarding and standalone AWS administration surfaces are now owned by the
  Haskell frontend; the retained Python helpers survive only for the legacy direct backend and the
  still-open real IAM lifecycle harness.

Implementation status, remaining work, and legacy-path removal are tracked in
[DEVELOPMENT_PLAN/README.md](./DEVELOPMENT_PLAN/README.md). Engineering docs under
`documents/engineering/` define doctrine and command contracts. Where a governed doc still
describes the Python baseline, the owning rewrite phase in `DEVELOPMENT_PLAN/` is authoritative
for the final handoff target.

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

## Current Worktree Bootstrap

### Prerequisites

- Current repository baseline: Python 3.12+ plus Poetry for the retained backend and dev tooling
- Haskell frontend build proof: GHC 9.6.x, `cabal-install` 3.14.x, and a linkable GMP
  development package such as `libgmp-dev`
- Ubuntu 24.04 LTS host with systemd
- kubectl, helm, docker, ctr, sudo, pulumi CLI tools
- AWS account with Route 53 hosted zone

### Install

```bash
# Clone the repository
git clone https://github.com/Tuee22/prodbox.git
cd prodbox

# Install project and dev dependencies
poetry install

# Verify the retained Python-backed entrypoint
poetry run prodbox --version

# Build the current Haskell frontend
cabal build --builddir=.build exe:prodbox
```

## Configuration

All configuration is authored in the repository-root `prodbox-config.dhall` (Dhall schema with
typed defaults) and compiled to `prodbox-config.json` by `prodbox config compile`. On the current
mixed baseline, `config compile|show|validate` are Haskell-owned while downstream Python runtime
consumers still read the materialized JSON via a Pydantic `BaseModel`. Both files are gitignored.
Cluster-internal secrets are auto-generated at chart deploy time and stored in
`.prodbox-state/<namespace>/.secrets.json`. IP addressing (MetalLB pool, ingress LB IP) is always
auto-discovered from the host LAN. Subprocess environments are built from explicit configuration
only; no `os.environ` credentials are inherited.

### Supported Onboarding

```bash
# Supported zero-to-config flow
poetry run prodbox config setup
```

The wizard explains where to create one temporary elevated credential in the AWS console, then
collects that credential, selects a live AWS region and Route 53 hosted zone, guides ACME
provider choice, creates the dedicated `prodbox` IAM user, writes `prodbox-config.dhall`,
compiles it, and validates the result.

### Manual Config Maintenance

```bash
# Recompile the repository-root Dhall config to JSON explicitly
poetry run prodbox config compile
```

### Required config fields

| Config Path | Description |
|-------------|-------------|
| `aws.access_key_id` | Operational AWS access key ID, normally written by `prodbox config setup` or `prodbox aws setup` |
| `aws.secret_access_key` | Operational AWS secret access key, normally written by `prodbox config setup` or `prodbox aws setup` |
| `route53.zone_id` | Route 53 hosted zone ID |
| `acme.email` | Email for the selected public ACME provider |

Required when using the chart platform and public `vscode` flow:

| Config Path | Description |
|-------------|-------------|
| `domain.vscode_fqdn` | Public FQDN for the namespace-local `vscode` and Keycloak ingress path |

Cluster-internal secrets (`KEYCLOAK_ADMIN_PASSWORD`, `KEYCLOAK_POSTGRES_PASSWORD`,
`KEYCLOAK_NGINX_CLIENT_SECRET`) are auto-generated at chart deploy time and stored in
`.prodbox-state/<namespace>/.secrets.json`. They do not appear in the config file.

### Optional fields (with defaults)

| Config Path | Default | Description |
|-------------|---------|-------------|
| `aws.region` | `us-east-1` | AWS region |
| `aws.session_token` | `None` | Optional AWS session token |
| `aws_admin.access_key_id` | empty | Test-only elevated admin key for `prodbox aws *` and `prodbox test integration aws-iam` |
| `aws_admin.secret_access_key` | empty | Test-only elevated admin secret |
| `aws_admin.session_token` | `None` | Optional test-only elevated session token |
| `aws_admin.region` | empty | Test-only elevated admin region |
| `domain.demo_fqdn` | `demo.example.com` | Domain name |
| `domain.demo_ttl` | `60` | DNS record TTL in seconds |
| `acme.server` | Let's Encrypt production | ACME server URL |
| `deployment.bootstrap_public_ip_override` | `None` | Bootstrap-only DNS A-record IP override |
| `storage.manual_pv_host_root` | `.data` | Host root reserved for retained PV contents |

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

Examples below show the canonical `prodbox` command surface. On the current mixed
baseline, either run them through `poetry run prodbox <command>` or build the Haskell
frontend with `cabal build --builddir=.build exe:prodbox` and invoke the resulting
`.build/.../prodbox` binary, which currently owns config, dns, gateway status/config generation, host,
k8s, check-code, tla-check, and test while delegating the remaining unported commands to the Python
backend.

### Check Prerequisites

```bash
# Verify required CLI tools
prodbox host ensure-tools

# Install or reconcile the supported local RKE2 cluster runtime
prodbox rke2 install

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

### AWS Validation Stacks

```bash
# Provision or inspect the canonical AWS EKS validation stack
poetry run prodbox pulumi eks-resources

# Provision or inspect the canonical AWS HA RKE2 validation stack
poetry run prodbox pulumi test-resources
```

### Manage DNS

```bash
# Check current DNS record
prodbox dns check
```

### Interactive Onboarding And AWS IAM

```bash
# Render the supported inline IAM policy
poetry run prodbox aws policy --tier full

# Create or refresh the operational IAM user
poetry run prodbox aws setup --tier full

# Inspect or request supported AWS service quotas
poetry run prodbox aws check-quotas
poetry run prodbox aws request-quotas --tier full
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
# Destroy the canonical AWS EKS validation stack
poetry run prodbox pulumi eks-destroy --yes

# Destroy the canonical AWS HA RKE2 validation stack
poetry run prodbox pulumi test-destroy --yes

# Destroy local Pulumi-managed cluster infrastructure
poetry run prodbox pulumi destroy

# Destructively remove the supported local RKE2 cluster while preserving retained host state
poetry run prodbox rke2 delete --yes
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
- Cluster-backed integration suites enforce `rke2 install` as a runbook gate before pytest starts.
- `poetry run prodbox test integration aws-iam` validates the real IAM lifecycle using `aws_admin.*` from the Dhall config.
- `poetry run prodbox test integration charts-vscode` is an external public-host suite and does not require cluster gates or `rke2 install`.
- `poetry run prodbox test integration public-dns` is the external authoritative delegation proof for the hosted zone that owns `VSCODE_FQDN`; it does not require cluster gates or `rke2 install`.
- The phase-two pytest timeout budget is 240 minutes.
- Real AWS DNS integration uses `poetry run prodbox test integration dns-aws` to validate the canonical gateway Route 53 write client against fixture-owned ephemeral hosted zones.
- Real public DNS delegation validation uses `poetry run prodbox test integration public-dns` to compare the public NS view with the canonical Route 53 hosted zone named by `ROUTE53_ZONE_ID`.
- Real Pulumi validation uses `poetry run prodbox test integration pulumi`, a local Pulumi backend, and a fixture-owned Route 53 hosted zone to exercise `stack-init`, `preview`, `up`, and `destroy` against isolated test state.

### Current Worktree Structure

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
| [aws_account_setup_guide.md](documents/engineering/aws_account_setup_guide.md) | AWS account creation and onboarding path for `prodbox config setup` |
| [aws_admin_credentials.md](documents/engineering/aws_admin_credentials.md) | Test-only elevated credential harness for `prodbox aws *` and `aws-iam` validation |
| [acme_provider_guide.md](documents/engineering/acme_provider_guide.md) | ZeroSSL vs Let's Encrypt operator guidance |
| [effectful_dag_architecture.md](documents/engineering/effectful_dag_architecture.md) | Effect DAG system design |
| [effect_interpreter.md](documents/engineering/effect_interpreter.md) | Interpreter runtime contract |
| [prerequisite_doctrine.md](documents/engineering/prerequisite_doctrine.md) | Fail-fast prerequisite philosophy |
| [prerequisite_dag_system.md](documents/engineering/prerequisite_dag_system.md) | Prerequisite DAG expansion and runtime |
| [streaming_doctrine.md](documents/engineering/streaming_doctrine.md) | Streaming serialization doctrine |
| [unit_testing_policy.md](documents/engineering/unit_testing_policy.md) | Interpreter-Only Mocking Doctrine |
| [dependency_management.md](documents/engineering/dependency_management.md) | Build and dependency doctrine, including rewrite-owned Python-toolchain removal |
| [pure_fp_standards.md](documents/engineering/pure_fp_standards.md) | Pure FP coding standards |
| [code_quality.md](documents/engineering/code_quality.md) | Guardrail and check-code doctrine |
| [refactoring_patterns.md](documents/engineering/refactoring_patterns.md) | Imperative to pure FP migration patterns |
| [distributed_gateway_architecture.md](documents/engineering/distributed_gateway_architecture.md) | P2P gateway design |
| [local_registry_pipeline.md](documents/engineering/local_registry_pipeline.md) | Harbor install + Docker build/push + mirror behavior |
| [storage_lifecycle_doctrine.md](documents/engineering/storage_lifecycle_doctrine.md) | Retained storage + deterministic PVC/PV rebinding doctrine |
| [helm_chart_platform_doctrine.md](documents/engineering/helm_chart_platform_doctrine.md) | Canonical chart-platform doctrine for `prodbox charts` |

## License

MIT License - see [LICENSE](LICENSE) for details.
