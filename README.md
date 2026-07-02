# Prodbox

**Status**: Reference only
**Supersedes**: N/A
**Referenced by**: CLAUDE.md, AGENTS.md, DEVELOPMENT_PLAN/README.md, [documents/engineering/vault_doctrine.md](./documents/engineering/vault_doctrine.md)
**Generated sections**: none

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
- The authoritative CLI doctrine is distributed across per-surface engineering docs under
  [documents/engineering/](./documents/engineering/README.md): command topology,
  progressive introspection, and reconcilers in `cli_command_surface.md`; Plan / Apply
  and GADT-indexed state machines in `pure_fp_standards.md`; project structure,
  subprocesses, smart constructors, error handling, capability classes, retry policy, and
  application environment in `haskell_code_guide.md`; generated artifacts and lint stack
  in `code_quality.md`; output rules and at-least-once event processing in
  `streaming_doctrine.md`; prerequisites as typed effects in `prerequisite_doctrine.md`;
  daemon lifecycle in `distributed_gateway_architecture.md`; unified block storage —
  static `Retain` no-provisioner PVs on both substrates (home `hostPath`, EKS pre-created
  EBS) and deterministic rebinding — in `storage_lifecycle_doctrine.md`; testing doctrine in
  `unit_testing_policy.md`; toolchain pinning in `dependency_management.md`. Phase
  documents in `DEVELOPMENT_PLAN/` cite doctrine sections by name when scheduling
  adoption work.
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
- The supported configuration contract is described by
  [documents/engineering/config_doctrine.md](./documents/engineering/config_doctrine.md):
  the in-force cluster configuration is the source of truth, stored as a
  prodbox application-level Vault-Transit envelope in the shared object-store — an
  opaque `objects/<id>.enc` entry in the one generically-named MinIO bucket, not a
  literal `in-force-config` key. The binary-sibling `prodbox.dhall` is a
  seed/propose input only — on first-ever bring-up it seeds the encrypted MinIO SSoT, and
  thereafter supplying a file is a proposed update, not the live config. Each `prodbox`
  binary instance reads the small unencrypted basics locally (cluster id, this cluster's
  Vault address, seal mode, and for a child the parent reference it contacts to auto-unseal)
  and fetches plus decrypts the in-force config from MinIO through Vault; in-cluster
  consumers authenticate to Vault directly via Vault Kubernetes auth, with no
  Secret-mounted plaintext Dhall credential fragments. `prodbox-config.json`,
  `prodbox config compile`, and `PRODBOX_*` environment-variable precedence are not part
  of the supported interface.
- The supported Pulumi scope is limited to the AWS validation stacks under `pulumi/aws-eks/`,
  `pulumi/aws-eks-subzone/`, `pulumi/aws-test/`, and `pulumi/aws-ses/`; local-cluster platform
  ownership does not use a root Pulumi project. The test harness is the exclusive owner of every
  AWS resource any `prodbox` flow may create or destroy; the authoritative inventory and
  per-resource lifecycle class (auto-managed per-run stacks vs long-lived cross-substrate shared
  infrastructure vs K8s-controller-created cluster-tagged AWS) live in
  [DEVELOPMENT_PLAN/substrates.md → Resource Lifecycle Classes](./DEVELOPMENT_PLAN/substrates.md#resource-lifecycle-classes).
- Block storage is unified across substrates: every PV is a static, no-provisioner, `Retain`,
  deterministically-rebinding volume — a `hostPath` under `.data/` on the home substrate, a
  **pre-created EBS volume lifted in as a static `Retain` PV** (CSI `volumeHandle`, AZ-pinned) on the
  AWS/EKS substrate. There is no dynamic provisioning on either substrate. Production retains the EBS
  volumes exactly as it retains `.data/`; the test harness deletes only test-scoped EBS at suite
  postflight, so test runs never leak block storage. prodbox creates its own dedicated EKS VPC (never
  the account default), and the test harness always provisions a fresh test VPC. See
  [documents/engineering/storage_lifecycle_doctrine.md](./documents/engineering/storage_lifecycle_doctrine.md).
- Lifecycle commands enforce leak-safety by refusing to proceed when residue is detected and by
  sweeping for cluster-tagged AWS resources after every destructive run; the consolidated doctrine
  lives in
  [documents/engineering/lifecycle_reconciliation_doctrine.md](./documents/engineering/lifecycle_reconciliation_doctrine.md).
  `prodbox cluster delete` defaults to a pure local cluster uninstall — it preserves `.data/`
  and never touches the per-run AWS Pulumi backend; when no RKE2 install is present it is a
  no-op success (`No RKE2 cluster to delete.`, exit 0). `--cascade` is the
  positive-framed "clean teardown" path that orchestrates K8s drain + per-run destroys + cluster
  uninstall + postflight tag sweep. The K8s drain phase tolerates the case where the Kubernetes
  cluster is already absent (partial teardown, first-time provisioning, repeated reruns): a quick
  reachability probe skips the drain with an operator-visible reason and the cascade continues to
  the per-run Pulumi destroys, so re-running `--cascade` against an already-torn-down host is safe.
  `prodbox nuke` is the operator-only total-teardown path that also destroys long-lived shared
  infrastructure.
- This target edge doctrine applies to the self-managed local-cluster path; the AWS validation
  stacks remain separate and do not currently provision MetalLB or Envoy Gateway.
- The current shipped edge workloads share the single public hostname
  `test.resolvefintech.com`, with Keycloak on `/auth`, `vscode` on `/vscode`, the API on `/api`,
  the WebSocket workload on `/ws`, Harbor on `/harbor`, and MinIO console on `/minio`.
- The Haskell `prodbox gateway ...` command group and `charts reconcile gateway` manage the separate
  distributed gateway daemon; they are not the Envoy Gateway public edge controller.
- Vault is the sole, finalized fail-closed secrets / KMS / PKI root of every prodbox-managed
  cluster. Every secret, credential, key, and certificate the stack uses is a Vault object
  (KV v2, Transit key, or PKI-issued cert); there is no second store and no plaintext fallback.
  The master-seed HMAC derivation model is retired (not extended): there is no master seed, no
  HMAC derivation, and no Secret-mounted Dhall credential fragments — every previously-derived
  secret is a Vault KV object fetched via Vault Kubernetes auth. Vault runs in-cluster on a
  durable `.data/`-backed PV (preserved across cluster wipes exactly like the MinIO PV; on the AWS
  substrate the same durable Vault PV is backed by a pre-created EBS volume retained across teardown
  identically) and is initialized exactly once, then only unsealed on each rebuild. Every prodbox-owned secret-bearing
  object — the in-force config, gateway state, and the Pulumi backend checkpoints — is a
  prodbox application-level Vault-Transit envelope (Model B), written under opaque
  Vault-keyed-HMAC names into one generically-named MinIO bucket that the host CLI and the
  in-cluster gateway daemon share through a single envelope/naming/index layer; the bucket-,
  object-, and stack-level names a sealed-Vault listing could enumerate therefore carry no
  signal. Pulumi never reads or writes MinIO directly and has no encryption role of its own:
  each operation decrypts its stack into a RAM-tmpfs `file://` backend, runs `pulumi`, then
  re-envelopes the checkpoint back to MinIO, and this interposition applies uniformly to both
  per-run and long-lived (`aws-ses`) backends. The TLS, Keycloak, Pulumi, and AWS-credential
  paths fail closed when Vault is sealed — a sealed Vault bricks the cluster, reducing it to an
  opaque durable-data pile that reveals no secrets, and no information about its children, until
  it is unsealed. Cluster federation forms a Vault
  transit-seal trust tree: a root cluster (Shamir-sealed, operator-unsealed) and child clusters
  that auto-unseal against their parent's Vault, with each parent holding custody of its children's
  init keys. The doctrine single source of truth is
  [documents/engineering/vault_doctrine.md](./documents/engineering/vault_doctrine.md), with the
  federation trust tree governed by
  [documents/engineering/cluster_federation_doctrine.md](./documents/engineering/cluster_federation_doctrine.md).

The development-plan target architecture centers the local public edge on:

- **MetalLB** for self-managed `LoadBalancer` IP allocation
- **Envoy Gateway** and **Gateway API** for public HTTP(S) routing
- **cert-manager** for listener TLS, rendering one ZeroSSL ACME `ClusterIssuer` whose
  certificate is issued once and retained as a long-lived S3 resource, then restored before
  every issuance so rebuild cycles never re-order it (Sprints 4.24/7.11/8.7;
  see [DEVELOPMENT_PLAN/README.md](./DEVELOPMENT_PLAN/README.md) and
  [acme_provider_guide.md](./documents/engineering/acme_provider_guide.md))
- **Keycloak** as the OIDC identity provider
- **Redis** only for shared realtime or rate-limit state, never for Envoy JWT caching

The current codebase baseline still deploys and manages:

- **RKE2** for the local Kubernetes lifecycle
- **Harbor** for the local registry, Harbor-first steady-state workload sourcing with a narrow
  public-registry bootstrap exception for Harbor storage-backend prerequisites, and native-host-
  architecture image publication
- **MinIO** for the local-cluster-first Pulumi backend
- **MetalLB**, **Envoy Gateway**, **Gateway API**, and **cert-manager** for the current cluster
  edge implementation
- **Percona Operator for PostgreSQL** for Helm-managed application databases, with namespace-local
  three-replica synchronous Patroni clusters and Harbor-backed PostgreSQL sidecar images
- **Route 53** for the single public A-record ownership contract
- **Interactive onboarding** through `prodbox config setup`
- **AWS IAM automation** through `prodbox aws ...`
- **AWS validation stacks** through `prodbox aws stack eks reconcile|eks destroy --yes|test reconcile|test destroy --yes`
- **Bespoke charts** for `gateway`, `keycloak`, `vscode`, `api`, and `websocket`, with internal
  `redis` and `keycloak-postgres` dependency releases

Implementation status, phase closure, and legacy-path removal are tracked in
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

Shared public hostname:
  https://test.resolvefintech.com/auth   -> Keycloak identity flow
  https://test.resolvefintech.com/vscode -> Envoy-protected browser app
  https://test.resolvefintech.com/api    -> JWT-protected API
  https://test.resolvefintech.com/ws     -> JWT-protected WebSocket workload
  https://test.resolvefintech.com/harbor -> Harbor admin surface
  https://test.resolvefintech.com/minio  -> MinIO console
```

### Network Design

- **Node IP**: the server's LAN IP
- **MetalLB pool**: a single dedicated LAN IP, sized to the one Envoy Gateway `LoadBalancer` Service that the supported edge needs
- **Public edge LB IP**: that single MetalLB-allocated IP, bound to the public-edge Envoy Gateway controller

Router port forwarding:

- `WAN:80 -> MetalLB IP:80`
- `WAN:443 -> MetalLB IP:443`
- `WAN:44444 -> Node IP:22`

### Current Implementation Baseline

The current worktree closes on the supported edge architecture. Today:

- local `cluster reconcile` reconciles Harbor, MinIO, MetalLB, Envoy Gateway, cert-manager, and the
  Percona PostgreSQL operator
- the public `vscode` path uses Gateway API `HTTPRoute` plus Envoy Gateway `SecurityPolicy`
- the public `api` route uses Gateway API `HTTPRoute` plus Envoy-local JWT validation and
  claim-based authorization
- the public `websocket` route uses Gateway API `HTTPRoute`, Envoy-local JWT validation, and a
  Redis-backed shared-state workload
- Keycloak uses the shared public hostname on the `/auth` path
- MetalLB supports config-selected L2 or BGP advertisement through repo-owned settings
- `edge status`, `charts-api`, `charts-websocket`, and `admin-routes` extend the external
  proof surface across the shared-host application and admin paths
- resource lifecycle is reconciled over a typed **managed-resource registry** — every AWS or
  cluster resource prodbox can create is registered with a `discover` + `destroy`, teardown is
  one idempotent reconciler with "cannot observe" never silently treated as "absent", and
  `dev check` makes a creatable-but-undiscoverable resource unrepresentable (doctrine:
  [lifecycle_reconciliation_doctrine.md § 3.1](./documents/engineering/lifecycle_reconciliation_doctrine.md);
  Phase 4 Sprints 4.20–4.22 and Phase 7 Sprint 7.8)

Closure, validation ownership, and phase history are tracked in
[DEVELOPMENT_PLAN/README.md](./DEVELOPMENT_PLAN/README.md).

## Install And Build

### Prerequisites

- GHC `9.12.4`
- `cabal-install` `3.16.1.0`
- A linkable GMP development package such as `libgmp-dev`
- Ubuntu `24.04 LTS` with systemd for the supported host runtime
- `kubectl`, `helm`, `docker`, `ctr`, `sudo`, `pulumi`, `aws`, `curl`, `dig`, `ssh`
- An AWS account with a Route 53 hosted zone

### Install

```bash
git clone https://github.com/Tuee22/prodbox.git
cd prodbox

cabal install exe:prodbox --builddir=.build --installdir=.build --install-method=copy --overwrite-policy=always
./.build/prodbox --help
```

`prodbox dev check` enforces the repository-owned workflow and hook policy, then syncs the built
operator binary to `./.build/prodbox`.

## Supported Operating Model

`prodbox` is not a thin wrapper around `kubectl`, `helm`, `pulumi`, or `aws`. The supported
operator path is the explicit `prodbox` command surface documented here and in
[documents/engineering/cli_command_surface.md](./documents/engineering/cli_command_surface.md).

- Most commands load and validate the binary-sibling `prodbox.dhall` (the Tier-0 config file
  beside the executable, `./.build/prodbox.dhall`, generated by `prodbox config generate` /
  `config setup`) before they do any work. See
  [config_doctrine.md](./documents/engineering/config_doctrine.md) §3.
- `prodbox cluster reconcile` is the idempotent local lifecycle entrypoint. Use it to create or
  reconcile the supported local cluster.
- `prodbox charts ...` manages the supported root chart stacks: `gateway`, `keycloak`, `vscode`,
  `api`, and `websocket`.
- `api` and `websocket` are public-edge chart surfaces alongside `keycloak` and `vscode`. The
  internal `redis` release is owned by the `websocket` stack. The `gateway` chart is the separate
  in-cluster Haskell distributed gateway daemon, not the Envoy Gateway controller.
- `prodbox aws stack ...` manages only the AWS validation stacks. It does not manage the local
  cluster or the application chart stacks.
- The AWS validation stacks use the repo-backed MinIO backend in the local RKE2 cluster, so
  `prodbox cluster reconcile` must succeed before `prodbox aws stack eks reconcile` or
  `prodbox aws stack test reconcile` can succeed.

## Quick Start

Use this sequence for a first supported local bring-up:

```bash
cabal install exe:prodbox --builddir=.build --installdir=.build --install-method=copy --overwrite-policy=always

./.build/prodbox config setup
./.build/prodbox config validate
./.build/prodbox config show

./.build/prodbox host ensure-tools
./.build/prodbox host check-ports
./.build/prodbox host firewall gateway-restrict

./.build/prodbox cluster reconcile
./.build/prodbox cluster status

./.build/prodbox charts reconcile vscode
./.build/prodbox charts reconcile api
./.build/prodbox charts reconcile websocket

./.build/prodbox edge status
./.build/prodbox charts status vscode
./.build/prodbox charts reconcile gateway
./.build/prodbox charts status gateway
```

What this does:

- `config setup` writes the supported Dhall config file.
- `host ...` verifies the host toolchain, port availability, and firewall assumptions.
- `cluster reconcile` reconciles the local substrate, including Harbor, MinIO, MetalLB, Envoy Gateway,
  cert-manager, and the Percona PostgreSQL operator.
- `charts reconcile vscode` deploys the `vscode` stack plus its supported dependencies:
  `keycloak` and the internal `keycloak-postgres` Patroni release, with the browser path protected
  by Envoy Gateway and Keycloak on the shared `/auth` path.
- `charts reconcile api` deploys the shared-host API workload on `/api`.
- `charts reconcile websocket` deploys the shared-host WebSocket workload plus its internal Redis
  dependency on `/ws`.
- `edge status` confirms Route 53, Envoy Gateway, Gateway API, and certificate readiness for
  the shared browser, API, WebSocket, Harbor, and MinIO edge paths (the public edge uses the
  single ZeroSSL ACME issuer with retained-and-restored certificate material; see
  [acme_provider_guide.md](./documents/engineering/acme_provider_guide.md)).
- `charts reconcile gateway` is optional for the separate Haskell distributed gateway daemon and is
  not required to bring up the Envoy Gateway public edge.

## Configuration

All supported configuration is authored in Dhall and decoded in-process by the native
Haskell `dhall` library. The in-force cluster configuration is the source of truth, held
as a prodbox application-level Vault-Transit envelope in the shared object-store — an
opaque-named entry in the one generically-named MinIO bucket; the binary-sibling
`prodbox.dhall` `parameters` sub-record
(validated against the schema in `prodbox-config-types.dhall`) is a seed/propose input
only, never the live SSoT. Each binary reads the small unencrypted basics locally to reach
and unseal Vault, then fetches and decrypts the in-force config through Vault; in-cluster
consumers read their secrets directly from Vault via Vault Kubernetes auth, with no
Secret-mounted credential fragments. The complete sourcing, seed/propose, and decryption
contract lives in
[documents/engineering/config_doctrine.md](./documents/engineering/config_doctrine.md).

Configuration separates into three tiers (the canonical definitions live in
[config_doctrine.md §0](./documents/engineering/config_doctrine.md#0-three-tier-config-model)):

- **Tier 0 — non-secret binary context**: a binary-owned, generated, self-contained (no
  imports) `prodbox.dhall` carrying parameters, context, and witness but never secrets. It
  *is* the sealed-Vault bootstrap floor — the binary decodes it and projects the basics
  directly; there is no separate JSON floor (the derived `prodbox-basics.json` is eliminated,
  Sprint 1.41). It lives at the **binary-sibling path** — the file beside the executable
  (`./.build/prodbox.dhall`), the same `prodbox.dhall` filename in every context (host,
  container, test harness), resolved via the executable path, not the repo root and not a
  `--config` flag. The binary owns its config and **fails fast** when the sibling file is
  absent; it is created only by running the binary (`config generate` / `config setup`) or by
  the test harness. Tier 0 is shaped to align with hostbootstrap's binary-owns-its-config
  contract, so the eventual refactor onto hostbootstrap is a clean extension rather than a
  rewrite.
- **Tier 1 — bootstrap secret (password-gated)**: the Vault unlock material is
  password-AEAD-sealed (Argon2id + ChaCha20-Poly1305) and lives in the durable MinIO
  bucket, read via a password-derived bootstrap MinIO credential — never on host disk, and
  root-cluster-only (child clusters auto-unseal via transit-seal).
- **Tier 2 — operational secrets (Vault-gated)**: all other secrets are opaque-named,
  Vault-Transit-enveloped objects in the same durable MinIO bucket, decryptable only with
  an unsealed Vault; config carries only `SecretRef.Vault` pointers that resolve here at
  use time.

Every `.dhall` file is generated or locally-authored, and none is
version-controlled (Sprint 1.41): the binary-sibling `prodbox.dhall` and the
`prodbox-config-types.dhall` / `test-secrets-types.dhall` schemas are generated, and
`test-secrets.dhall` is the git-ignored harness fixture. There is **no committed container
default** — the in-container `prodbox.dhall` is generated at image-build time by running the
binary (`prodbox config generate`) at the binary-sibling path, never a `COPY`-ed
`default-prodbox.dhall` (Sprint 1.49). The binary-sibling `prodbox.dhall` is the seed/propose
input for the in-force MinIO SSoT; it carries no plaintext secrets, only typed `SecretRef`
references. See
[config_doctrine.md §0](./documents/engineering/config_doctrine.md#0-three-tier-config-model).

- `prodbox config setup` writes and validates Dhall directly.
- `prodbox config show` renders the decoded Haskell settings model, masking secrets by default.
- `prodbox config validate` verifies the required fields and binding rules.
- No supported command materializes `prodbox-config.json` or any other JSON projection.
- No supported `prodbox` binary reads `PRODBOX_*` environment variables for runtime
  configuration; `--config <path>` is the sole startup-time CLI knob.
- `prodbox config show --show-secrets` reveals full secret values when you explicitly need them.

### Secret References (SecretRef)

Sensitive configuration fields carry typed `SecretRef` values — a Dhall union of
`Vault | TransitKey | Prompt | TestPlaintext` — rather than inline plaintext secrets. `Vault` and
`TransitKey` are the production targets; there is no `FileSecret` arm and no Secret-mounted Dhall
fragment path. `prodbox config validate` rejects plaintext secrets in production config; all
test-only plaintext — including the `aws_admin_for_test_simulation.*` simulation fixture that
feeds the operator prompts non-interactively — lives only in `test-secrets.dhall`, which is never
imported by production config and is never stored in Vault. The seed/propose
`prodbox.dhall` holds references in place of raw secret material; the in-force config it
seeds is the Vault-encrypted MinIO object. The authoritative model is
[documents/engineering/vault_doctrine.md](./documents/engineering/vault_doctrine.md) (see
[§3 The SecretRef model](./documents/engineering/vault_doctrine.md#3-the-secretref-model) and
[§4 Config split](./documents/engineering/vault_doctrine.md#4-config-split-production-references-vs-test-plaintext)).

> **Note**: the `aws.access_key_id`, `aws.secret_access_key`, and `acme.eab_*` fields listed below
> are `SecretRef.Vault` references, not inline plaintext (Sprints 1.35 / 7.15). The generated
> operational `prodbox` `aws.*` credential is minted into Vault KV after Vault is unsealed, and
> production config carries only the typed Vault reference to it. The Validation-Required-Fields
> table stays valid as the field inventory; only the value form is a typed Vault reference.

### Supported Onboarding

```bash
./.build/prodbox config setup
```

The wizard guides AWS account setup, Route 53 zone selection, ACME provider choice, operational IAM
bootstrap, and binary-sibling Dhall authoring (`./.build/prodbox.dhall`). On the supported public path it prompts for one
temporary, ephemeral admin AWS credential set when needed (historically called "elevated
credential") — the operator types it at the interactive `SecretRef.Prompt`; it is used once to
mint the dedicated least-privilege `prodbox` IAM identity and then discarded, never written to
production config or stored in Vault. The `aws_admin_for_test_simulation.*` block is not a
reserved production config section; it is a test-harness fixture living only in
`test-secrets.dhall` that simulates that prompt so the suite can drive admin-credentialed flows
non-interactively.

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
| `domain.demo_ttl` | DNS TTL in seconds |
| `acme.server` | ZeroSSL ACME directory URL (the issuer for the once-issued, S3-retained public-edge certificate); defaults to the ZeroSSL endpoint |
| `deployment.bootstrap_public_ip_override` | Bootstrap-only DNS A-record IP override |
| `deployment.pulumi_enable_dns_bootstrap` | Bootstrap toggle for DNS reconciliation during the supported flow |
| `deployment.public_edge_bgp_peers` | Optional BGP peer list when `deployment.public_edge_advertisement_mode = Some "bgp"` |

`aws_admin_for_test_simulation.*` is **not** a production config field — it is a
`TestPlaintext`-class test-harness fixture in `test-secrets.dhall` (see
[aws_admin_credentials.md](./documents/engineering/aws_admin_credentials.md)) that simulates the
operator's interactive admin-credential prompt; it is never read by any production binary and never
stored in Vault.

Validate the repository config:

```bash
./.build/prodbox config validate
```

## Command Map

| Area | Commands | Use When |
|------|----------|----------|
| Config | `config setup`, `config show`, `config validate`, `config schema`, `config generate` | You need to create, inspect, validate, or regenerate the supported `prodbox.dhall` / schema artifacts |
| Host checks | `host ensure-tools`, `host check-ports`, `host info`, `host firewall gateway-restrict`, `host firewall gateway-unrestrict` | You need to verify the host runtime or manage the gateway NodePort firewall rule |
| Public edge | `edge status`, `edge reconcile` | You need to diagnose or reconcile public DNS, Gateway API, and certificate readiness |
| Local cluster lifecycle | `cluster reconcile`, `cluster status`, `cluster health`, `cluster start`, `cluster stop`, `cluster restart`, `cluster logs`, `cluster wait`, `cluster workload-logs`, `cluster delete --yes`, `cluster delete --cascade`, `nuke` | You need to create, reconcile, inspect, or remove the local RKE2 environment. `cluster delete --yes` is a local uninstall that preserves retained roots and leaves per-run AWS stacks untouched. `--cascade` is the leak-safe "wipe and rebuild" path that also destroys per-run AWS stacks and drains K8s-controller-created AWS resources; `prodbox nuke` is the operator-only total-teardown path that also destroys long-lived shared infrastructure. |
| Chart lifecycle | `charts list`, `charts status`, `charts reconcile`, `charts delete --yes` | You need to manage the supported `gateway`, `keycloak`, `vscode`, `api`, or `websocket` chart stacks |
| Gateway operations | `gateway config-gen`, `gateway start --config <path>`, `gateway status --config <path>` | You need to generate a gateway config, run a daemon manually, or inspect daemon state |
| DNS | `dns check` | You need Route 53 inspection for the configured public host |
| AWS IAM and quotas | `aws policy`, `aws setup`, `aws teardown`, `aws quotas check`, `aws quotas request` | You need IAM bootstrap, cleanup, or supported quota inspection/request flows |
| AWS validation stacks | `aws stack eks reconcile`, `aws stack eks destroy --yes`, `aws stack aws-subzone reconcile`, `aws stack aws-subzone destroy --yes`, `aws stack test reconcile`, `aws stack test destroy --yes`, `aws stack aws-ses reconcile`, `aws stack aws-ses destroy --yes` | You need to create, inspect, or destroy the AWS EKS, Route 53 subzone, HA-RKE2, or SES validation stacks (see [DEVELOPMENT_PLAN/substrates.md → Resource Lifecycle Classes](./DEVELOPMENT_PLAN/substrates.md#resource-lifecycle-classes) for which stacks the test harness auto-destroys vs retains) |
| Vault | `vault status`, `vault init`, `vault unseal`, `vault seal`, `vault reconcile`, `vault rotate-unlock-bundle`, `vault rotate-transit-key`, `vault pki ...` | You need to initialize, unseal, seal, or reconcile the in-cluster Vault that backs cluster secrets (see [vault_doctrine.md](./documents/engineering/vault_doctrine.md#7-vault-lifecycle-commands)) |
| Validation | `dev check`, `dev lint ...`, `dev docs ...`, `test lint`, `test ...`, `dev tla-check` | You need quality gates, generated-doc maintenance, Haskell tests, native integration validation, or TLA+ checks |

## Common Workflows

### Local Platform Lifecycle

Bring up or reconcile the supported local substrate:

```bash
./.build/prodbox cluster reconcile
./.build/prodbox cluster status
./.build/prodbox cluster health
```

Inspect local platform logs:

```bash
./.build/prodbox cluster logs -n 200
./.build/prodbox cluster workload-logs --tail 200
```

Remove the local runtime while preserving retained local roots and leaving AWS validation stacks alone:

```bash
./.build/prodbox cluster delete --yes
```

`cluster delete --yes` is destructive to the local runtime only. It removes the local cluster,
removes the managed kubeconfig, preserves `.data/` as the sole retained operator-host directory,
and does **not** destroy per-run AWS validation stacks. Use `cluster delete --cascade` when the
intended cleanup also includes per-run AWS stacks and Kubernetes-controller-created AWS resources.
The per-run Pulumi state lives on MinIO's PV under
`.data/prodbox/minio/0` and Vault's durable storage lives on its own retained PV under
`.data/vault/vault/0`, so both survive cluster wipes whenever `.data/` is preserved. `prodbox`
never deletes `.data/`; removing it is an operator-only action. A cluster rebuild is therefore not
a fresh Vault: `vault init` runs exactly once (the first time the PV is empty) and every later
`cluster reconcile` only unseals the existing data, so Vault KV is as durable across rebuilds as
any retained PV. Invoking `rke2 delete` when no local RKE2 cluster is installed is a
no-op success (`No RKE2 cluster to delete.`, exit 0), not an error.

### Chart Stacks

See supported root charts:

```bash
./.build/prodbox charts list
```

Deploy or inspect supported chart stacks:

```bash
./.build/prodbox charts reconcile gateway
./.build/prodbox charts reconcile keycloak
./.build/prodbox charts reconcile vscode
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
./.build/prodbox edge status
```

`edge status` is the main supported readiness diagnostic for the public host. The successful
state is `CLASSIFICATION=ready-for-external-proof`. That classification derives from Route 53,
Envoy Gateway, Gateway API, `SecurityPolicy`, certificate readiness, and the shared-host path
contract.

### Gateway Operations

Generate a gateway config and inspect a daemon:

```bash
./.build/prodbox gateway config-gen gateway.json --node-id node-a
./.build/prodbox gateway start --config gateway.json
./.build/prodbox gateway status --config gateway.json
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
./.build/prodbox aws quotas check
./.build/prodbox aws quotas request --tier full
```

The supported public `aws ...` flow prompts for an ephemeral temporary admin credential when
needed — including the long-lived `aws-ses` stack operations and `prodbox nuke`. There is exactly
one runtime path by which elevated admin power enters prodbox: the interactive `SecretRef.Prompt`.
The test harness automates that prompt by reading `aws_admin_for_test_simulation.*` from
`test-secrets.dhall` (a test fixture, never a production config section and never a Vault
object); there is no production config-backed admin path.

### AWS Validation Stacks

Use the local cluster-backed MinIO backend to create or inspect the AWS validation stacks:

```bash
./.build/prodbox cluster reconcile

./.build/prodbox aws stack eks reconcile
./.build/prodbox aws stack test reconcile
```

Destroy them explicitly:

```bash
./.build/prodbox aws stack eks destroy --yes
./.build/prodbox aws stack test destroy --yes
```

These stacks are for repository validation, not for the local application runtime. `aws stack eks
reconcile` provisions a dedicated VPC (never the account default) and attaches the platform's
durable block storage as pre-created EBS volumes lifted in as static `Retain` PVs (CSI
`volumeHandle`, AZ-pinned) — the AWS analog of the home `.data/` hostPath PVs. `aws stack eks
destroy --yes` retains those EBS volumes in production workflows exactly as `cluster delete`
preserves `.data/`; only the test harness deletes test-scoped EBS, and only at suite postflight, so
test runs never leak block storage. See
[documents/engineering/storage_lifecycle_doctrine.md](./documents/engineering/storage_lifecycle_doctrine.md).

## Validation

### Fast Local Validation

Use these commands for quick feedback that stays local:

```bash
./.build/prodbox dev check
./.build/prodbox test unit
./.build/prodbox test integration cli
./.build/prodbox test integration env
```

`dev check` is the canonical local quality gate. It runs the repository-owned policy scan,
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
./.build/prodbox test integration sealed-vault
```

`./.build/prodbox test integration sealed-vault` asserts the fail-closed invariant: a sealed Vault leaves PVs and MinIO
objects intact while revealing no secrets, no active Dhall, no Pulumi state, and no downstream
inventory until Vault is unsealed (see
[vault_doctrine.md §2 The fail-closed invariant](./documents/engineering/vault_doctrine.md#2-the-fail-closed-invariant)
and [§15 Sealed-state behavior matrix](./documents/engineering/vault_doctrine.md#15-sealed-state-behavior-matrix)).

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

### Substrate Independence (No Fallback)

The canonical test suite is composed of per-substrate runs against both supported substrates —
the home local substrate and the AWS substrate. A complete canonical-suite proof requires both
runs to land independently against their own real infrastructure (DNS, TLS via cert-manager,
ingress, charts, public-edge proofs). Each per-substrate run is substrate-locked: it targets
exactly one substrate, consumes only that substrate's operator-supplied config, and fails fast
if any required substrate config is missing. There is no silent fallback from the AWS substrate
to home values or vice versa. The two substrates stand up the same service set and the same
block-storage discipline (static `Retain` no-provisioner PVs, deterministic rebinding), differing
only in their lower layer — ingress load-balancer, Route 53 hosting, and the PV volume source
(`hostPath` under `.data/` on home, pre-created EBS on EKS). Select the substrate with
`--substrate {home-local|aws}` on `prodbox test integration ...` and `prodbox test all`; the
default is `home-local`. The authoritative doctrine lives in
[DEVELOPMENT_PLAN/development_plan_standards.md → M. Substrate coverage and independence (no fallback)](DEVELOPMENT_PLAN/development_plan_standards.md#substrate-coverage-and-independence-no-fallback)
and the per-substrate `Required Config` inventory lives in
[DEVELOPMENT_PLAN/substrates.md](DEVELOPMENT_PLAN/substrates.md).

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
- [Documentation Standards](./documents/documentation_standards.md)
- [CLI Command Surface](./documents/engineering/cli_command_surface.md)
- [Code Quality Doctrine](./documents/engineering/code_quality.md)
- [Lifecycle Reconciliation Doctrine](./documents/engineering/lifecycle_reconciliation_doctrine.md)
- [Storage Lifecycle Doctrine](./documents/engineering/storage_lifecycle_doctrine.md)
- [Vault Secret-Management Doctrine](./documents/engineering/vault_doctrine.md)
- [Unit Testing Policy](./documents/engineering/unit_testing_policy.md)
