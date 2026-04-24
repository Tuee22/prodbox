# Prodbox

**Status**: Reference only
**Supersedes**: N/A
**Referenced by**: CLAUDE.md, AGENTS.md, DEVELOPMENT_PLAN/README.md

> **Purpose**: Project overview, installation guide, and documentation index for `prodbox`.

Home Kubernetes cluster management with a Haskell CLI and Pulumi-backed AWS validation stacks.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

## Overview

Prodbox is a Haskell-first repository for managing a home Kubernetes cluster and its AWS-backed
validation environments.

- The authoritative target architecture, sprint status, and cleanup ownership live in
  [DEVELOPMENT_PLAN/README.md](./DEVELOPMENT_PLAN/README.md).
- The repository is Haskell-only on the supported path: the public CLI, lifecycle runtime, Pulumi
  orchestration, gateway runtime, chart platform, onboarding flow, AWS administration commands,
  and test harness all live under `app/`, `src/Prodbox/`, `test/`, `prodbox.cabal`,
  `cabal.project`, and `docker/`.
- The supported configuration contract is repository-root `prodbox-config.dhall` decoded directly
  into Haskell types. `prodbox-config.json` and `prodbox config compile` are not part of the
  supported interface.
- The supported Pulumi scope is limited to the AWS validation stacks under `pulumi/aws-eks/` and
  `pulumi/aws-test/`; local-cluster platform ownership does not use a root Pulumi project.

The current repository baseline deploys and manages:

- **RKE2** for the local Kubernetes lifecycle
- **Harbor** for the local registry, Harbor-first steady-state workload sourcing with a narrow
  public-registry bootstrap exception for Harbor storage-backend prerequisites, and the dual-arch
  image pipeline
- **MinIO** for the local-cluster-first Pulumi backend
- **MetalLB**, **Traefik**, and **cert-manager** for the cluster edge
- **Zalando Patroni PostgreSQL** for Helm-managed application databases, with namespace-local
  three-replica synchronous clusters
- **Route 53** for explicit per-subdomain DNS ownership
- **Interactive onboarding** through `prodbox config setup`
- **AWS IAM automation** through `prodbox aws ...`
- **AWS validation stacks** through `prodbox pulumi eks-resources|eks-destroy --yes|test-resources|test-destroy --yes`
- **Bespoke charts** for `gateway`, `keycloak`, and `vscode`

Implementation status, remaining work, and legacy-path removal are tracked in
[DEVELOPMENT_PLAN/README.md](./DEVELOPMENT_PLAN/README.md). Engineering docs under
`documents/engineering/` define doctrine and command contracts.

## Architecture

```text
Internet -> Router (80/443 port-forward) -> MetalLB IP -> Traefik -> Services -> Pods
                                                         |
                                                         +-> cert-manager
```

### Network Design

- **Node IP**: the server's LAN IP
- **MetalLB pool**: a dedicated IP range for `LoadBalancer` services
- **Ingress LB IP**: the reserved Traefik `LoadBalancer` IP

Router port forwarding:

- `WAN:80 -> MetalLB IP:80`
- `WAN:443 -> MetalLB IP:443`
- `WAN:44444 -> Node IP:22`

## Bootstrap

### Prerequisites

- GHC `9.6.x`
- `cabal-install` `3.14.x`
- A linkable GMP development package such as `libgmp-dev`
- Ubuntu `24.04 LTS` with systemd for the supported host runtime
- `kubectl`, `helm`, `docker`, `ctr`, `sudo`, `pulumi`, `aws`, `curl`, `dig`, `ssh`
- An AWS account with a Route 53 hosted zone

### Install

```bash
git clone https://github.com/Tuee22/prodbox.git
cd prodbox

cabal build --builddir=.build exe:prodbox
./.build/prodbox --help
```

`prodbox check-code` also syncs the built operator binary to `./.build/prodbox`.

## Configuration

All supported configuration is authored in the repository-root `prodbox-config.dhall` using the
schema in `prodbox-config-types.dhall`.

- `prodbox config setup` writes and validates Dhall directly.
- `prodbox config show` renders the decoded Haskell settings model, masking secrets by default.
- `prodbox config validate` verifies the required fields and binding rules.
- No supported command materializes `prodbox-config.json`.

### Supported Onboarding

```bash
./.build/prodbox config setup
```

The wizard guides AWS account setup, Route 53 zone selection, ACME provider choice, operational IAM
bootstrap, and repository-root Dhall authoring. On the supported public path it prompts for one
temporary elevated AWS credential set when needed; `aws_admin.*` remains reserved for the native
IAM lifecycle test harness.

### Required Config Fields

| Config Path | Description |
|-------------|-------------|
| `aws.access_key_id` | Operational AWS access key ID |
| `aws.secret_access_key` | Operational AWS secret access key |
| `route53.zone_id` | Route 53 hosted zone ID |
| `acme.email` | Email for the selected public ACME provider |

Required when using the chart platform and public `vscode` flow:

| Config Path | Description |
|-------------|-------------|
| `domain.vscode_fqdn` | Public FQDN for the namespace-local `vscode` and Keycloak ingress path |

### Optional Fields

| Config Path | Description |
|-------------|-------------|
| `aws.region` | Operational AWS region |
| `aws.session_token` | Optional AWS session token |
| `aws_admin.*` | Test-harness-only elevated admin credential exception for `prodbox test integration aws-iam` |
| `domain.demo_fqdn` | Gateway/public-edge FQDN |
| `domain.demo_ttl` | DNS TTL in seconds |
| `acme.server` | ACME server URL |
| `deployment.bootstrap_public_ip_override` | Bootstrap-only DNS A-record IP override |
| `storage.manual_pv_host_root` | Host root reserved for retained PV contents |

Validate the repository config:

```bash
./.build/prodbox config validate
```

## Usage

### Check Prerequisites

```bash
./.build/prodbox host ensure-tools
./.build/prodbox rke2 install
./.build/prodbox rke2 status
```

### Bootstrap Local Platform

```bash
./.build/prodbox rke2 install
./.build/prodbox charts deploy vscode
```

### AWS Validation Stacks

```bash
./.build/prodbox pulumi eks-resources
./.build/prodbox pulumi test-resources
```

### DNS, Gateway, And Charts

```bash
./.build/prodbox dns check
./.build/prodbox host public-edge
./.build/prodbox gateway config-gen gateway.json --node-id node-1
./.build/prodbox charts deploy vscode
./.build/prodbox charts status vscode
```

### AWS IAM And Quotas

```bash
./.build/prodbox aws policy --tier full
./.build/prodbox aws setup --tier full
./.build/prodbox aws check-quotas
./.build/prodbox aws request-quotas --tier full
```

## Validation

Local closure commands:

```bash
./.build/prodbox check-code
./.build/prodbox test unit
./.build/prodbox test integration cli
./.build/prodbox test integration env
```

Named infrastructure-backed validation commands are part of the supported surface and run real
native Haskell validation flows:

- `./.build/prodbox test integration aws-iam`
- `./.build/prodbox test integration dns-aws`
- `./.build/prodbox test integration aws-eks`
- `./.build/prodbox test integration pulumi`
- `./.build/prodbox test integration ha-rke2-aws`
- `./.build/prodbox test integration gateway-daemon`
- `./.build/prodbox test integration gateway-pods`
- `./.build/prodbox test integration gateway-partition`
- `./.build/prodbox test integration charts-platform`
- `./.build/prodbox test integration charts-storage`
- `./.build/prodbox test integration charts-vscode`
- `./.build/prodbox test integration public-dns`
- `./.build/prodbox test integration lifecycle`

These suites require the real tools, credentials, cluster state, DNS state, or AWS resources named
by their prerequisite contracts.

## Repository Layout

```text
prodbox/
├── app/prodbox/          # Haskell executable entrypoint
├── src/Prodbox/          # Haskell runtime, CLI, infra, and library modules
├── test/                 # Haskell unit and integration suites
├── documents/engineering/# Engineering doctrine and architecture docs
├── DEVELOPMENT_PLAN/     # Canonical plan, phase status, and cleanup ownership
├── docker/               # Canonical container builds under /opt/build
├── prodbox.cabal         # Cabal package definition
├── cabal.project         # Cabal project definition
```

## Documentation

- [Development Plan](./DEVELOPMENT_PLAN/README.md)
- [Engineering Docs Index](./documents/engineering/README.md)
- [CLI Command Surface](./documents/engineering/cli_command_surface.md)
- [Code Quality Doctrine](./documents/engineering/code_quality.md)
- [Unit Testing Policy](./documents/engineering/unit_testing_policy.md)
