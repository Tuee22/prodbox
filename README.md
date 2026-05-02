# Prodbox

**Status**: Reference only
**Supersedes**: N/A
**Referenced by**: CLAUDE.md, AGENTS.md, DEVELOPMENT_PLAN/README.md

> **Purpose**: Project overview, operator guide, installation guide, and documentation index for
> `prodbox`.

Home Kubernetes cluster management with a Haskell CLI, a MetalLB + Envoy Gateway + Keycloak
public edge, and Pulumi-backed AWS validation stacks.

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
- The target self-managed public edge is documented in
  [documents/engineering/envoy_gateway_edge_doctrine.md](./documents/engineering/envoy_gateway_edge_doctrine.md):
  MetalLB exposes an Envoy Gateway `LoadBalancer`, Gateway API owns Layer 7 routing, Keycloak
  remains the identity provider, Envoy Gateway `SecurityPolicy` owns the browser-auth path, Envoy
  validates the shipped JWT API routes locally, and the Redis plus WebSocket boundaries are
  defined there.
- The supported configuration contract is repository-root `prodbox-config.dhall` decoded directly
  into Haskell types. `prodbox-config.json` and `prodbox config compile` are not part of the
  supported interface.
- The supported Pulumi scope is limited to the AWS validation stacks under `pulumi/aws-eks/` and
  `pulumi/aws-test/`; local-cluster platform ownership does not use a root Pulumi project.
- This target edge doctrine applies to the self-managed local-cluster path; the AWS validation
  stacks remain separate and do not currently provision MetalLB or Envoy Gateway.
- The current shipped edge workloads share the single public hostname
  `test.resolvefintech.com`, with Keycloak on `/auth`, `vscode` on `/vscode`, the API on `/api`,
  the WebSocket workload on `/ws`, Harbor on `/harbor`, and MinIO console on `/minio`.
- The Haskell `prodbox gateway ...` command group and `charts deploy gateway` manage the separate
  distributed gateway daemon; they are not the Envoy Gateway public edge controller.

The development-plan target architecture centers the local public edge on:

- **MetalLB** for self-managed `LoadBalancer` IP allocation
- **Envoy Gateway** and **Gateway API** for public HTTP(S) routing
- **cert-manager** for listener TLS
- **Keycloak** as the OIDC identity provider
- **Redis** only for shared realtime or rate-limit state, never for Envoy JWT caching

The current codebase baseline still deploys and manages:

- **RKE2** for the local Kubernetes lifecycle
- **Harbor** for the local registry, Harbor-first steady-state workload sourcing with a narrow
  public-registry bootstrap exception for Harbor storage-backend prerequisites, and the dual-arch
  image pipeline
- **MinIO** for the local-cluster-first Pulumi backend
- **MetalLB**, **Envoy Gateway**, **Gateway API**, and **cert-manager** for the current cluster
  edge implementation
- **Percona Operator for PostgreSQL** for Helm-managed application databases, with namespace-local
  three-replica synchronous Patroni clusters and Harbor-backed PostgreSQL sidecar images
- **Route 53** for the single public A-record ownership contract
- **Interactive onboarding** through `prodbox config setup`
- **AWS IAM automation** through `prodbox aws ...`
- **AWS validation stacks** through `prodbox pulumi eks-resources|eks-destroy --yes|test-resources|test-destroy --yes`
- **Bespoke charts** for `gateway`, `keycloak`, `vscode`, `api`, and `websocket`, with internal
  `redis` and `keycloak-postgres` dependency releases

Implementation status, remaining work, and legacy-path removal are tracked in
[DEVELOPMENT_PLAN/README.md](./DEVELOPMENT_PLAN/README.md). Engineering docs under
`documents/engineering/` define doctrine and command contracts.

## Target Architecture

```text
Internet
  -> Router (80/443 port-forward)
  -> MetalLB IP
  -> Envoy service
  -> Gateway API listeners and routes
  -> Services
  -> Pods

Dedicated public hosts:
  auth.<zone>   -> Keycloak identity flow
  vscode.<zone> -> Envoy-protected browser app
  api.<zone>    -> JWT-protected API
  ws.<zone>     -> JWT-protected WebSocket workload
```

### Network Design

- **Node IP**: the server's LAN IP
- **MetalLB pool**: a dedicated IP range for `LoadBalancer` services
- **Public edge LB IP**: the reserved MetalLB `LoadBalancer` IP for the edge controller

Router port forwarding:

- `WAN:80 -> MetalLB IP:80`
- `WAN:443 -> MetalLB IP:443`
- `WAN:44444 -> Node IP:22`

### Current Implementation Baseline

The current worktree closes on the supported edge architecture. Today:

- local `rke2 install` reconciles Harbor, MinIO, MetalLB, Envoy Gateway, cert-manager, and the
  Percona PostgreSQL operator
- the public `vscode` path uses Gateway API `HTTPRoute` plus Envoy Gateway `SecurityPolicy`
- the public `api` route uses Gateway API `HTTPRoute` plus Envoy-local JWT validation and
  claim-based authorization
- the public `websocket` route uses Gateway API `HTTPRoute`, Envoy-local JWT validation, and a
  Redis-backed shared-state workload
- Keycloak uses the shared public hostname on the `/auth` path
- MetalLB supports config-selected L2 or BGP advertisement through repo-owned settings
- `host public-edge`, `charts-api`, and `charts-websocket` extend the external proof surface to
  the dedicated API and WebSocket hosts

Closure, validation ownership, and phase history are tracked in
[DEVELOPMENT_PLAN/README.md](./DEVELOPMENT_PLAN/README.md).

## Install And Build

### Prerequisites

- GHC `9.14.1`
- `cabal-install` `3.16.1.0`
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

`prodbox check-code` enforces the repository-owned workflow and hook policy, then syncs the built
operator binary to `./.build/prodbox`.

## Supported Operating Model

`prodbox` is not a thin wrapper around `kubectl`, `helm`, `pulumi`, or `aws`. The supported
operator path is the explicit `prodbox` command surface documented here and in
[documents/engineering/cli_command_surface.md](./documents/engineering/cli_command_surface.md).

- Most commands load and validate the repository-root `prodbox-config.dhall` before they do any
  work.
- `prodbox rke2 install` is the idempotent local lifecycle entrypoint. Use it to create or
  reconcile the supported local cluster.
- `prodbox charts ...` manages the supported root chart stacks: `gateway`, `keycloak`, `vscode`,
  `api`, and `websocket`.
- `api` and `websocket` are public-edge chart surfaces alongside `keycloak` and `vscode`. The
  internal `redis` release is owned by the `websocket` stack. The `gateway` chart is the separate
  in-cluster Haskell distributed gateway daemon, not the Envoy Gateway controller.
- `prodbox pulumi ...` manages only the AWS validation stacks. It does not manage the local
  cluster or the application chart stacks.
- The AWS validation stacks use the repo-backed MinIO backend in the local RKE2 cluster, so
  `prodbox rke2 install` must succeed before `prodbox pulumi eks-resources` or
  `prodbox pulumi test-resources` can succeed.

## Quick Start

Use this sequence for a first supported local bring-up:

```bash
cabal build --builddir=.build exe:prodbox

./.build/prodbox config setup
./.build/prodbox config validate
./.build/prodbox config show

./.build/prodbox host ensure-tools
./.build/prodbox host check-ports
./.build/prodbox host firewall

./.build/prodbox rke2 install
./.build/prodbox rke2 status

./.build/prodbox charts deploy vscode
./.build/prodbox charts deploy api
./.build/prodbox charts deploy websocket

./.build/prodbox host public-edge
./.build/prodbox charts status vscode
./.build/prodbox charts deploy gateway
./.build/prodbox charts status gateway
```

What this does:

- `config setup` writes the supported Dhall config file.
- `host ...` verifies the host toolchain, port availability, and firewall assumptions.
- `rke2 install` reconciles the local substrate, including Harbor, MinIO, MetalLB, Envoy Gateway,
  cert-manager, and the Percona PostgreSQL operator.
- `charts deploy vscode` deploys the `vscode` stack plus its supported dependencies:
  `keycloak` and the internal `keycloak-postgres` Patroni release, with the browser path protected
  by Envoy Gateway and Keycloak on the shared `/auth` path.
- `charts deploy api` deploys the shared-host API workload on `/api`.
- `charts deploy websocket` deploys the shared-host WebSocket workload plus its internal Redis
  dependency on `/ws`.
- `host public-edge` confirms Route 53, Envoy Gateway, Gateway API, and certificate readiness for
  the shared browser, API, WebSocket, Harbor, and MinIO edge paths.
- `charts deploy gateway` is optional for the separate Haskell distributed gateway daemon and is
  not required to bring up the Envoy Gateway public edge.

## Configuration

All supported configuration is authored in the repository-root `prodbox-config.dhall` using the
schema in `prodbox-config-types.dhall`.

- `prodbox config setup` writes and validates Dhall directly.
- `prodbox config show` renders the decoded Haskell settings model, masking secrets by default.
- `prodbox config validate` verifies the required fields and binding rules.
- No supported command materializes `prodbox-config.json`.
- `prodbox config show --show-secrets` reveals full secret values when you explicitly need them.

### Supported Onboarding

```bash
./.build/prodbox config setup
```

The wizard guides AWS account setup, Route 53 zone selection, ACME provider choice, operational IAM
bootstrap, and repository-root Dhall authoring. On the supported public path it prompts for one
temporary elevated AWS credential set when needed; `aws_admin_for_test_simulation.*` is reserved
only for test-suite simulation of that ephemeral prompt input, with the native IAM lifecycle test
harness as the only supported runtime consumer.

### Validation-Required Fields

| Config Path | Description |
|-------------|-------------|
| `aws.access_key_id` | Operational AWS access key ID |
| `aws.secret_access_key` | Operational AWS secret access key |
| `route53.zone_id` | Route 53 hosted zone ID |
| `acme.email` | Email for the selected public ACME provider |

### Operationally Important Fields

These fields are not all parser-required, but they matter for normal operation:

| Config Path | Description |
|-------------|-------------|
| `domain.demo_fqdn` | Primary public FQDN used by DNS inspection, public-edge diagnostics, and the gateway/public host flow |
| `deployment.public_edge_advertisement_mode` | Optional MetalLB advertisement mode: `l2` or `bgp` |
| `deployment.envoy_gateway_controller_replicas` | Optional Envoy Gateway controller replica count |
| `deployment.envoy_gateway_data_plane_replicas` | Optional Envoy data-plane replica count |
| `deployment.api_replicas` | Optional API workload replica count |
| `deployment.websocket_replicas` | Optional WebSocket workload replica count |
| `aws.region` | Operational AWS region; the default config value is `us-east-1` |
| `storage.manual_pv_host_root` | Host root reserved for retained PV contents; defaults to `.data` under the repo |

### Optional Fields

| Config Path | Description |
|-------------|-------------|
| `aws.session_token` | Optional AWS session token |
| `aws_admin_for_test_simulation.*` | Test-suite-only stored simulation of the ephemeral elevated admin credential prompt; only `prodbox test integration aws-iam` consumes it at runtime |
| `domain.demo_ttl` | DNS TTL in seconds |
| `acme.server` | ACME server URL |
| `deployment.bootstrap_public_ip_override` | Bootstrap-only DNS A-record IP override |
| `deployment.pulumi_enable_dns_bootstrap` | Bootstrap toggle for DNS reconciliation during the supported flow |
| `deployment.public_edge_bgp_peers` | Optional BGP peer list when `deployment.public_edge_advertisement_mode = Some "bgp"` |

Validate the repository config:

```bash
./.build/prodbox config validate
```

## Command Map

| Area | Commands | Use When |
|------|----------|----------|
| Config | `config setup`, `config show`, `config validate` | You need to create, inspect, or validate `prodbox-config.dhall` |
| Host checks | `host ensure-tools`, `host check-ports`, `host firewall`, `host info`, `host public-edge` | You need to verify the host runtime or diagnose the public edge and certificate state |
| Local cluster lifecycle | `rke2 install`, `rke2 status`, `rke2 start`, `rke2 stop`, `rke2 restart`, `rke2 logs`, `rke2 delete --yes` | You need to create, reconcile, inspect, or remove the local RKE2 environment |
| Chart lifecycle | `charts list`, `charts status`, `charts deploy`, `charts delete --yes` | You need to manage the supported `gateway`, `keycloak`, or `vscode` chart stacks |
| Kubernetes helpers | `k8s health`, `k8s wait`, `k8s logs` | You need cluster or workload diagnostics without dropping into raw `kubectl` |
| Gateway operations | `gateway config-gen`, `gateway start`, `gateway status` | You need to generate a gateway config, run a daemon manually, or inspect daemon state |
| DNS | `dns check` | You need Route 53 inspection for the configured public host |
| AWS IAM and quotas | `aws policy`, `aws setup`, `aws teardown`, `aws check-quotas`, `aws request-quotas` | You need IAM bootstrap, cleanup, or supported quota inspection/request flows |
| AWS validation stacks | `pulumi eks-resources`, `pulumi eks-destroy --yes`, `pulumi test-resources`, `pulumi test-destroy --yes` | You need to create, inspect, or destroy the AWS EKS or HA-RKE2 validation stacks |
| Validation | `check-code`, `test ...`, `tla-check` | You need quality gates, Haskell tests, native integration validation, or TLA+ checks |

## Common Workflows

### Local Platform Lifecycle

Bring up or reconcile the supported local substrate:

```bash
./.build/prodbox rke2 install
./.build/prodbox rke2 status
./.build/prodbox k8s health
```

Inspect local platform logs:

```bash
./.build/prodbox rke2 logs -n 200
./.build/prodbox k8s logs --tail 200
```

Remove the local runtime and destroy AWS validation residue:

```bash
./.build/prodbox rke2 delete --yes
```

`rke2 delete --yes` is destructive. It removes the local cluster, destroys the AWS validation
stacks if they still exist, removes the managed kubeconfig, and preserves the retained state roots
under `.data/` and `.prodbox-state/`.

### Chart Stacks

See supported root charts:

```bash
./.build/prodbox charts list
```

Deploy or inspect supported chart stacks:

```bash
./.build/prodbox charts deploy gateway
./.build/prodbox charts deploy keycloak
./.build/prodbox charts deploy vscode
./.build/prodbox charts status gateway
./.build/prodbox charts status keycloak
./.build/prodbox charts status vscode
```

Delete a chart stack while preserving retained host storage:

```bash
./.build/prodbox charts delete gateway --yes
./.build/prodbox charts delete keycloak --yes
./.build/prodbox charts delete vscode --yes
```

### Public Edge And DNS Diagnostics

Check the external Route 53 record and public edge state:

```bash
./.build/prodbox dns check
./.build/prodbox host public-edge
```

`host public-edge` is the main supported readiness diagnostic for the public host. The successful
state is `CLASSIFICATION=ready-for-external-proof`. That classification derives from Route 53,
Envoy Gateway, Gateway API, `SecurityPolicy`, certificate readiness, and the shared-host path
contract.

### Gateway Operations

Generate a gateway config and inspect a daemon:

```bash
./.build/prodbox gateway config-gen gateway.json --node-id node-a
./.build/prodbox gateway start gateway.json
./.build/prodbox gateway status gateway.json
```

`gateway status` queries the daemon's HTTP `/v1/state` endpoint on the configured REST port.
This `gateway` command group refers to the Haskell distributed gateway daemon, not the Kubernetes
Gateway API or Envoy Gateway edge controller.

### AWS IAM And Quotas

Use these commands when you need to render policies, create or refresh the operational IAM user, or
inspect/request supported AWS quotas:

```bash
./.build/prodbox aws policy --tier full
./.build/prodbox aws setup --tier full
./.build/prodbox aws teardown
./.build/prodbox aws check-quotas
./.build/prodbox aws request-quotas --tier full
```

The supported public `aws ...` flow prompts for temporary elevated credentials when needed.
`aws_admin_for_test_simulation.*` is not part of the public operator path.

### AWS Validation Stacks

Use the local cluster-backed MinIO backend to create or inspect the AWS validation stacks:

```bash
./.build/prodbox rke2 install

./.build/prodbox pulumi eks-resources
./.build/prodbox pulumi test-resources
```

Destroy them explicitly:

```bash
./.build/prodbox pulumi eks-destroy --yes
./.build/prodbox pulumi test-destroy --yes
```

These stacks are for repository validation, not for the local application runtime.

## Validation

### Fast Local Validation

Use these commands for quick feedback that stays local:

```bash
./.build/prodbox check-code
./.build/prodbox test unit
./.build/prodbox test integration cli
./.build/prodbox test integration env
```

`check-code` is the canonical local quality gate. It runs the repository-owned policy scan,
Fourmolu, HLint, a warning-clean Cabal build, and syncs the built executable to `./.build/prodbox`.

### Named Infrastructure-Backed Validation

These commands run real native Haskell validation flows against the named environment:

```bash
./.build/prodbox test integration aws-iam
./.build/prodbox test integration dns-aws
./.build/prodbox test integration aws-eks
./.build/prodbox test integration pulumi
./.build/prodbox test integration ha-rke2-aws
./.build/prodbox test integration gateway-daemon
./.build/prodbox test integration gateway-pods
./.build/prodbox test integration gateway-partition
./.build/prodbox test integration charts-platform
./.build/prodbox test integration charts-storage
./.build/prodbox test integration charts-vscode
./.build/prodbox test integration public-dns
./.build/prodbox test integration lifecycle
```

### Full End-To-End Validation

Run the aggregate suites only when you want the full repository proof:

```bash
./.build/prodbox test integration all
./.build/prodbox test all
```

`test all` is long-running and destructive. It can:

- create and destroy real AWS resources
- reconcile and delete the local cluster
- deploy and delete supported chart stacks
- run public-edge and certificate convergence checks
- restore the supported local runtime before returning

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
