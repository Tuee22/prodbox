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
- The lifecycle-control-plane redesign is planned and the affected implementation phases are
  reopened. The current revision is not deployment-qualified for a seamless aggregate suite. See
  [Development Plan → Current Plan Status](./DEVELOPMENT_PLAN/README.md#current-plan-status); this
  reference guide does not maintain a competing status ledger.
- The authoritative CLI doctrine is distributed across per-surface engineering docs under
  [documents/engineering/](./documents/engineering/README.md): command topology,
  progressive introspection, and reconcilers in `cli_command_surface.md`; Plan / Apply
  and GADT-indexed state machines in `pure_fp_standards.md`; project structure,
  subprocesses, smart constructors, error handling, capability classes, retry policy, and
  application environment in `haskell_code_guide.md`; generated artifacts and lint stack
  in `code_quality.md`; output rules and at-least-once event processing in
  `streaming_doctrine.md`; prerequisites as typed effects in `prerequisite_doctrine.md`;
  operation-indexed readiness and admission in `bootstrap_readiness_doctrine.md`; the physical
  Bootstrap Broker, Lifecycle Authority, Target Secret Agent, and gateway isolation boundary in
  `lifecycle_control_plane_architecture.md`;
  daemon lifecycle in `distributed_gateway_architecture.md`; unified block storage —
  static `Retain` no-provisioner PVs on both substrates (home `hostPath`, EKS pre-created
  EBS) and deterministic rebinding — in `storage_lifecycle_doctrine.md`; testing doctrine in
  `unit_testing_policy.md`; explicit cpu/ram/storage budgets, RKE2 reservations, namespace quotas,
  and chart resource envelopes in `resource_scaling_doctrine.md`; toolchain pinning in
  `dependency_management.md`. Phase
  documents in `DEVELOPMENT_PLAN/` cite doctrine sections by name when scheduling
  adoption work.
- The repository is Haskell-only on the supported path: the public CLI, lifecycle runtime, Pulumi
  orchestration, gateway runtime, chart platform, onboarding flow, AWS administration commands,
  and test harness all live under `app/`, `src/Prodbox/`, `test/`, `prodbox.cabal`,
  `cabal.project`, and `docker/`.
- Messaging payloads are CBOR-only. The gateway `Orders`/event surfaces, durable event store, and
  Pulsar `Work*` envelopes use canonical CBOR through the self-maintained Haskell client boundary;
  any Pulsar client implementation lives in this repository (or in a maintained fork vendored into
  it), not in a second runtime or generated external schema layer. See
  [documents/engineering/pulsar_messaging_doctrine.md](./documents/engineering/pulsar_messaging_doctrine.md).
- The target self-managed public edge is documented in
  [documents/engineering/envoy_gateway_edge_doctrine.md](./documents/engineering/envoy_gateway_edge_doctrine.md):
  MetalLB exposes an Envoy Gateway `LoadBalancer`, Gateway API owns Layer 7 routing, Keycloak
  remains the identity provider, Envoy Gateway `SecurityPolicy` owns the browser-auth path, Envoy
  validates the shipped JWT API routes locally, and the Redis plus WebSocket boundaries are
  defined there.
- The supported configuration contract is described by
  [documents/engineering/config_doctrine.md](./documents/engineering/config_doctrine.md):
  the in-force cluster configuration is an immutable application-level Vault-Transit envelope — an
  opaque `objects/<id>.enc` entry in the one generically-named MinIO bucket, not a
  literal `in-force-config` key — but it is current only when the Lifecycle Authority aggregate
  names its schema, digest, reference, and generation. The binary-sibling `prodbox.dhall` is a
  seed/propose input only: on first-ever bring-up it submits a visible absent-generation proposal,
  and thereafter supplying a file is a proposed update, not the live config. Each `prodbox`
  binary instance reads the small unencrypted basics locally (cluster id, this cluster's
  Vault address, seal mode, and for a child the parent reference it contacts to auto-unseal)
  and observes only its role-scoped config projection through Lifecycle Authority; in-cluster
  secret consumers authenticate to Vault directly via Kubernetes auth, with no
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
  the account default), tags the VPC/IGW/route-table/subnets with `prodbox.io/managed-by=prodbox`
  for postflight sweep visibility, and the test harness always provisions a fresh test VPC. See
  [documents/engineering/storage_lifecycle_doctrine.md](./documents/engineering/storage_lifecycle_doctrine.md).
- Resource admission and containment are explicit: host capacity, RKE2 reservations, eviction floors,
  namespace quotas, per-container cpu/memory/ephemeral-storage request+limit envelopes, and durable
  PVC capacities are part of the typed capacity plan, not template-local defaults. A prodbox cluster
  that reserves more than the host has, a workload set that exceeds cluster allocatable capacity, or
  a chart container without a limit is invalid before render; runtime reconciliation installs the
  matching RKE2/kubelet guardrails, Kubernetes `ResourceQuota` / `LimitRange`, and chart
  `resources` stanzas. Those declarations do not by themselves prove an arbitrary program's peak
  working set. Sprint `1.60` adds a validated nested runtime-memory plan (bounded heap state/scratch
  within an RTS heap cap, then heap cap plus native/subprocess/kernel reserves and margin within the
  profile-derived cgroup limit) and generates the gateway RTS argv. Sprint `5.16` now feeds that
  plan's thresholds into the run-scoped restart/OOM/high-water oracle used by `gateway-pods`. See
  [documents/engineering/resource_scaling_doctrine.md](./documents/engineering/resource_scaling_doctrine.md).
- A `LongLived` lifecycle class controls cleanup, not desired presence. When an invite-capable suite
  is selected, the target plan visibly reconciles the registered `aws-ses` stack through the
  retained home/control-plane Lifecycle Authority, awaits semantic SES readiness, then materializes
  the SMTP generation from its retained-home Transit-sealed custody through attested one-shot home
  and selected-substrate Agent workers. A fresh AWS Vault therefore does not require an admin
  re-prompt or key rotation; ordinary suite postflight destroys neither the stack nor that custody.
  See
  [DEVELOPMENT_PLAN/phase-4-lifecycle-canonical-paths.md](./DEVELOPMENT_PLAN/phase-4-lifecycle-canonical-paths.md)
  and [DEVELOPMENT_PLAN/phase-5-canonical-test-suite.md](./DEVELOPMENT_PLAN/phase-5-canonical-test-suite.md).
- Lifecycle commands enforce leak-safety through exact registered ownership/read-back. The owning
  whole-system surfaces—`cluster delete --cascade`, suite postflight, and `nuke`—also perform the
  applicable fail-closed cluster-tag sweep; plain local/individual destroys do not invent a global sweep. The consolidated doctrine
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
  infrastructure. Its target protocol requires the signed manifest plus exact digest-pinned
  Decommission Runner artifact/schema/verifier to be fsynced and reopened outside every deletion
  target before Authority may stop. Interruption resumes only with that same build/schema; TLS prefix versions/identity are removed without deleting the
  shared bucket, and only the final Authority-backup node may delete that bucket after every
  registered prefix is absent.
- This target edge doctrine has substrate-specific lower layers: the home substrate uses MetalLB,
  while the AWS substrate uses the AWS Load Balancer Controller/NLB path. Both substrates provision
  Envoy Gateway, Gateway API, cert-manager, and the same shared service set through their
  substrate-aware installers.
- The current shipped edge workloads share the single public hostname
  `test.resolvefintech.com`, with Keycloak on `/auth`, `vscode` on `/vscode`, the API on `/api`,
  the WebSocket workload on `/ws`, and the MinIO console on `/minio`. The in-cluster registry has
  no web UI and therefore no public-edge route.
- The Haskell `prodbox gateway ...` command group and `charts reconcile gateway` manage the separate
  distributed gateway daemon; they are not the Envoy Gateway public edge controller.
- Vault is the fail-closed KMS, PKI, and post-unseal operational-secret root for every managed
  cluster. The only non-Vault secret classes are the bounded Tier-1 bootstrap transaction and an
  ephemeral operator prompt that is never persisted. Before first init, the transaction read-backs
  a password-AEAD `PreparedInitEnvelope`; it then retains Vault's PGP-encrypted init response until
  the final password-AEAD unlock bundle is atomically promoted and read back. The master-seed and
  Secret-mounted credential models are retired. Vault has retained storage, is initialized once,
  and is subsequently only unsealed/reconciled. Its initial root token is PGP-encrypted to a pinned
  burn public key whose private key is never generated, stored, accepted, or available to `prodbox`
  and has no known holder; that ciphertext is never decrypted or used. Bounded baseline work uses a
  separately generated, accessor-audited session that is revoked and observed absent.
- Lifecycle Authority, not a host or Gateway object proxy, owns the generation/digest references
  selecting immutable Transit-enveloped config and Pulumi checkpoint blobs. Pulumi decrypts only
  into bounded scratch storage for one operation. Gateway continuity instead lives in an encrypted,
  identity-bound local retained journal and is never a shared Model-B object. Bootstrap Broker and
  Lifecycle Authority have separate least-privilege object-store capabilities; Gateway Runtime has
  none. Sealed-state listings and logs reveal no logical object, stack, or child identity.
- Cluster federation forms a Vault transit-seal trust tree. A parent holds only encrypted child
  recovery material and revocation attestations, releases it through an attested one-time recovery
  protocol, and never persists or transports a reusable child initial root token. The doctrine
  single source of truth is
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
- **`registry:2`** (single-binary CNCF distribution) for the local registry — a `registry:2`
  Deployment plus a NodePort Service (nodePort `30080`) applied with `kubectl apply` (no Helm),
  with registry-backed steady-state workload sourcing, a narrow public-registry bootstrap exception
  for the registry's MinIO/S3 storage-backend prerequisites, anonymous HTTP push, and native-host-
  architecture image publication (its namespace and Service retain the historical `harbor` name)
- **MinIO** for the local-cluster-first Pulumi backend
- **MetalLB**, **Envoy Gateway**, **Gateway API**, and **cert-manager** for the current cluster
  edge implementation
- **Percona Operator for PostgreSQL** for Helm-managed application databases, with namespace-local
  three-replica synchronous Patroni clusters and registry-backed PostgreSQL sidecar images
- **Route 53** for the single public A-record ownership contract
- **Interactive onboarding** through `prodbox config setup`
- **AWS IAM automation** through `prodbox aws ...`
- **AWS validation stacks** through `prodbox aws stack <stack> reconcile|destroy --yes` for
  `eks`, `aws-subzone`, `test`, and `aws-ses`
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

### Lifecycle Control Plane

The target topology separates pre-Vault recovery, retained lifecycle authority, substrate-local
secret delivery, and Gateway mesh/DNS into independent failure and resource domains. The canonical
topology diagram and dependency order live only in
[lifecycle_control_plane_architecture.md](./documents/engineering/lifecycle_control_plane_architecture.md#1-boundary-ownership).

- The Bootstrap Broker owns only bounded pre-Vault initialization, unlock, status, and rotation.
- Exactly one logical Lifecycle Authority in the retained home control plane owns durable
  operation IDs, authority epochs, fencing, checkpoints, provider revisions, credential
  generations, and target-delivery intents; the ephemeral AWS substrate receives a client
  reference, never a second writer.
- Physically separate Authority Backup and TLS Retention Adapters, the fenced Provider Worker,
  mode-indexed Credential Provisioner, and explicit Admin Action Runner each interpret only their
  closed capability program. The post-export Decommission Runner is outside the live control plane.
- A Target Secret Agent owns allowlisted payload sealing plus generation-checked Vault KV
  observe/CAS/read-back on one substrate and an exact TLS-Secret lane. The retained home Agent also
  owns payload-specific Transit-sealed custody/rewrap for the closed SMTP and ACME-EAB schemas, plus
  TLS DEK exchange. One-shot home/selected workers transfer only attestation-encrypted payloads;
  long-lived controllers receive ciphertext and typed receipts, never plaintext or a generic export.
- The Gateway Runtime owns mesh, continuity, ownership projection and, on home only, the
  registered Gateway-DNS effect. EKS Gateway DNS mutation is disabled.
- Capability observation, admission, and execution use one operation-indexed `CapabilityRef` and one
  propagated absolute deadline.

The pure-functional types, interpreter boundaries, cutover invariants, and verification obligations
are authoritative in
[lifecycle_control_plane_architecture.md](./documents/engineering/lifecycle_control_plane_architecture.md).

### Current Implementation Baseline

The edge, chart, Vault, MinIO, and Haskell CLI surfaces remain available, but the existing gateway-
backed lifecycle authority and readiness binding are superseded implementation. A full-suite run
showed CPU-throttled gateway replicas timing out both the nominal deep readiness request and the
retained SES lease/release path; the AWS precondition also observed a different endpoint from the
home authority used for execution. The same failed run showed that local chart restoration is not
finally guaranteed after a retained-resource failure.

The repository therefore does not currently claim deployment qualification or seamless aggregate
suite execution. Historical sprint results remain recorded in the development plan, while the
reopened phase chain owns capability indexing, native clients, process isolation, durable workflow,
always-run cleanup, and current-revision home/AWS qualification.

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
- The target AWS validation path submits durable operations to the retained Lifecycle Authority,
  which promotes immutable encrypted checkpoints only after primary MinIO and independent S3
  backup read-back, so
  `prodbox cluster reconcile` must succeed before `prodbox aws stack eks reconcile` or
  `prodbox aws stack test reconcile` can succeed.
- The target control plane is capability-mediated, not routed through one generic daemon. A
  minimal Bootstrap Broker owns pre-Vault recovery; a retained Lifecycle Authority owns durable
  decisions while private Backup/TLS adapters and Provider/Credential workers own their exact
  effects; substrate-local Target Secret Agents own generation-checked secret delivery; and Gateway
  Runtime owns only mesh and home DNS. The old combined-daemon routes and direct host
  transports remain pre-cutover legacy tracked in
  [DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md](./DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md).

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

- `config setup` writes/validates non-secret Tier-0 coordinates only; it creates no IAM/S3 resource.
- `host ...` verifies the host toolchain, port availability, and firewall assumptions.
- On first `cluster reconcile`, MinIO/Vault/Broker and the home Agent plus Authority/Backup Adapter
  start frozen. A visible, attested one-shot credential provisioner uses the ephemeral admin prompt
  to establish/read back the independent backup; only then does normal config/identity/platform
  reconciliation open. The command also installs registry, MetalLB, Envoy Gateway, cert-manager,
  and the Percona PostgreSQL operator.
- `charts reconcile vscode` deploys the `vscode` stack plus its supported dependencies:
  `keycloak` and the internal `keycloak-postgres` Patroni release, with the browser path protected
  by Envoy Gateway and Keycloak on the shared `/auth` path.
- `charts reconcile api` deploys the shared-host API workload on `/api`.
- `charts reconcile websocket` deploys the shared-host WebSocket workload plus its internal Redis
  dependency on `/ws`.
- `edge status` confirms Route 53, Envoy Gateway, Gateway API, and certificate readiness for
  the shared browser, API, WebSocket, and MinIO edge paths (the public edge uses the
  single ZeroSSL ACME issuer with retained-and-restored certificate material; see
  [acme_provider_guide.md](./documents/engineering/acme_provider_guide.md)).
- `charts reconcile gateway` reconciles the separate mesh/DNS Gateway Runtime and is not required
  to bring up the Envoy Gateway public edge. Bootstrap Broker, Lifecycle Authority, and Target
  Secret Agent are distinct control-plane components in the target cluster plan, not gateway
  modes.

## Configuration

All supported configuration is authored in Dhall and decoded in-process by the native
Haskell `dhall` library. The in-force cluster configuration is an immutable
Vault-Transit-enveloped blob named by schema/digest/reference/generation in the Lifecycle Authority
aggregate; the binary-sibling
`prodbox.dhall` `parameters` sub-record
(validated against the schema in `prodbox-config-types.dhall`) is a seed/propose input
only, never the live SSoT. The Bootstrap Broker reads only the bounded non-secret bootstrap
projection needed to reach and unseal Vault. Post-unseal components observe only role-scoped config
projections through Lifecycle Authority and fetch their own secrets through Vault Kubernetes auth, with no
Secret-mounted credential fragments. The complete sourcing, seed/propose, and decryption
contract lives in
[documents/engineering/config_doctrine.md](./documents/engineering/config_doctrine.md).

Configuration has three tiers: non-secret binary bootstrap context, password-gated Vault recovery
material, and Vault-gated operational secrets/encrypted state. Their exact contents, paths,
generation rules, and bootstrap protocol are defined only in
[config_doctrine.md §0](./documents/engineering/config_doctrine.md#0-three-tier-config-model).

Every `.dhall` file is generated or locally-authored, and none is
version-controlled (Sprint 1.41): the binary-sibling `prodbox.dhall` and the
`prodbox-config-types.dhall` / `test-secrets-types.dhall` schemas are generated, and
`test-secrets.dhall` is the git-ignored harness fixture. There is **no committed container
default** — the in-container `prodbox.dhall` is generated at image-build time by running the
binary (`prodbox config generate`) at the binary-sibling path, never a `COPY`-ed
`default-prodbox.dhall` (Sprint 1.49). The binary-sibling `prodbox.dhall` is the seed/propose
input for Lifecycle Authority; it carries no plaintext secrets, only non-secret topology and
role/capability coordinates. See
[config_doctrine.md §0](./documents/engineering/config_doctrine.md#0-three-tier-config-model).

- `prodbox config setup` writes and validates Dhall directly.
- `prodbox config show` renders the decoded Haskell settings model, masking secrets by default.
- `prodbox config validate` verifies the required fields and binding rules.
- No supported command materializes `prodbox-config.json` or any other JSON projection.
- No supported `prodbox` binary reads `PRODBOX_*` environment variables for runtime
  configuration; `--config <path>` is the sole startup-time CLI knob.
- The current `prodbox config show --show-secrets` flag is pre-cutover legacy. Sprint `1.61`
  removes the unrestricted reveal path; target `ConfigObserve` returns only a role-scoped,
  validated projection and has no generic secret-reveal capability.

### Secret References (SecretRef)

Sensitive configuration fields carry typed `SecretRef` values — a Dhall union of
`Vault | TransitKey | Prompt | TestPlaintext` — rather than inline plaintext secrets. `Vault` and
`TransitKey` are the production targets; there is no `FileSecret` arm and no Secret-mounted Dhall
fragment path. `prodbox config validate` rejects plaintext secrets in production config; all
test-only plaintext — including the `aws_admin_for_test_simulation.*` simulation fixture that
feeds the operator prompts non-interactively — lives only in `test-secrets.dhall`, which is never
imported by production config and is never stored in Vault. The seed/propose
`prodbox.dhall` holds non-secret role coordinates in place of raw secret material; the in-force
config it proposes becomes current only when Lifecycle Authority commits its encrypted blob
reference and generation. The authoritative model is
[documents/engineering/vault_doctrine.md](./documents/engineering/vault_doctrine.md) (see
[§3 The SecretRef model](./documents/engineering/vault_doctrine.md#3-the-secretref-model) and
[§4 Config split](./documents/engineering/vault_doctrine.md#4-config-split-production-references-vs-test-plaintext)).

> **Target credential boundary**: `prodbox.dhall` contains no AWS access key or shared `aws.*`
> reference. Lifecycle-provider, Authority-backup, TLS-retention, Gateway-DNS, and per-substrate
> cert-manager-DNS01 identities have
> separate IAM resources, Vault paths, policies, generations, consumers, and lifecycle classes;
> the deterministic SMTP IAM family and its retained-home `SesSmtpSource` custody are separate again.
> Ordinary teardown removes the Operational Lifecycle-provider and AWS-run DNS01 identities only;
> Authority-backup, TLS-retention, home Gateway-DNS, home DNS01, SMTP family, and SMTP custody are
> LongLived. Backup is nuke-
> only; TLS/home-DNS may also leave through explicit consumer decommission after exact dependent
> absence. Total teardown uses the external-receipt `nuke` protocol. The
> existing root `aws.access_key_id` / `aws.secret_access_key` fields are pre-cutover legacy tracked
> for removal; do not treat them as the target configuration model.

### Supported Onboarding

```bash
./.build/prodbox config setup
```

The target wizard authors and validates only the non-secret binary-sibling Tier-0 boot/proposal
coordinates (`./.build/prodbox.dhall`), including Route 53 and ACME choices. Credentialed effects
start only from their explicit lifecycle command. For the three AWS-admin proof families, a
mode-indexed `CredentialProvisionPermit` creates an attested Credential Provisioner, a disjoint
`AdminActionPermit` creates an Admin Action Runner, and signed-manifest export plus Authority stop
admits the standalone Decommission Runner. Each accepts a typed AWS-admin frame through the same
authenticated linear transport only for its closed action. ACME EAB uses that transport mechanism
with a distinct schema-indexed external-material frame and its own `OperatorMaterialPermit`; it can
never be supplied by the AWS-admin frame or `config setup`. Secret bytes are never argv,
environment, Kubernetes-object, production-config, Authority, Provider, Gateway, disk, or log data.
Only closed payloads reach their explicitly permitted Agent/Vault custody boundary. The
`aws_admin_for_test_simulation.*` block is not a
reserved production config section; it is a test-harness fixture living only in
`test-secrets.dhall` that simulates that prompt so the suite can drive admin-credentialed flows
non-interactively.

### Validation-Required Fields

| Config Path | Description |
|-------------|-------------|
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
| `domain.demo_ttl` | DNS TTL in seconds |
| `acme.server` | ZeroSSL ACME directory URL (the issuer for the once-issued, S3-retained public-edge certificate); defaults to the ZeroSSL endpoint |
| `deployment.bootstrap_public_ip_override` | Bootstrap-only DNS A-record IP override |
| `deployment.pulumi_enable_dns_bootstrap` | Bootstrap toggle for DNS reconciliation during the supported flow |
| `deployment.public_edge_bgp_peers` | Optional BGP peer list when `deployment.public_edge_advertisement_mode = Some "bgp"` |

The current decoder still accepts the pre-cutover root `aws.session_token` field alongside the
shared access-key fields named above. It is not part of the target role-scoped configuration and
is removed by Sprint `4.50`; new design work must not add consumers.

`aws_admin_for_test_simulation.*` is **not** a production config field — it is a
`TestPlaintext`-class test-harness fixture in `test-secrets.dhall` (see
[aws_admin_credentials.md](./documents/engineering/aws_admin_credentials.md)) that simulates the
operator's interactive admin-credential prompt; it is never read by any production binary and never
stored in Vault.

Validate the executable-sibling operator config:

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
| Vault | `vault status`, `vault init`, `vault unseal`, `vault seal`, `vault reconcile`, `vault rotate-unlock-bundle`, `vault rotate-transit-key`, `vault pki ...` | You need to initialize, unseal, seal, or reconcile the in-cluster Vault that backs cluster secrets. The target binds bounded bootstrap leaves to the exact Bootstrap Broker capability and post-unseal work to least-privilege Vault interpreters; combined gateway and direct-host routes are pre-cutover legacy tracked in the cleanup ledger (see [vault_doctrine.md](./documents/engineering/vault_doctrine.md#7-vault-lifecycle-commands)) |
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
any retained PV. Invoking `cluster delete` when no local RKE2 cluster is installed is a
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
./.build/prodbox gateway config-gen gateway.dhall --node-id node-a
./.build/prodbox gateway start --config gateway.dhall
./.build/prodbox gateway status --config gateway.dhall
```

`gateway status` queries the daemon's HTTP `/v1/state` endpoint on the configured REST port.
This `gateway` command group refers to the Haskell distributed gateway daemon, not the Kubernetes
Gateway API or Envoy Gateway edge controller.

### AWS IAM And Quotas

Use these command names to render policies, reconcile role identities, or inspect/request supported
AWS quotas:

```bash
./.build/prodbox aws policy --tier full
./.build/prodbox aws setup --tier full
./.build/prodbox aws teardown
./.build/prodbox aws quotas check
./.build/prodbox aws quotas request --tier full
```

The supported public `aws ...` flow prompts for an ephemeral temporary admin credential only after
an attested Credential Provisioner, Admin Action Runner, or post-export Decommission Runner is
bound to its disjoint permit/manifest. Normal stack work uses the already sealed Lifecycle-provider
generation. Total `nuke` begins only after the signed decommission manifest and exact digest-pinned
standalone runner artifact/schema/verifier are durable/read back outside every deletion target;
only then may Authority permanently stop and the runner accept a fresh prompt. Resume rejects a
different build or schema before prompt or mutation. There is exactly one
raw-byte ingress for these three permitted consumers: the authenticated `SecretRef.Prompt` stream
to the attested ephemeral process.
The test harness automates that prompt by reading `aws_admin_for_test_simulation.*` from
`test-secrets.dhall` (a test fixture, never a production config section and never a Vault
object); there is no production config-backed admin path.

The current binary's `aws setup|teardown` implementation still creates/deletes one shared
operational IAM user; that is the explicitly pre-cutover behavior recorded in the deletion ledger,
not the target contract. Target `config setup` authors/validates Tier 0 only. On the first
`cluster reconcile`, Vault/Broker/home Target Agent/Authority/Backup Adapter come up in the frozen
genesis topology; one ephemeral admin prompt establishes and receipts the LongLived backup, then
normal Authority admission can reconcile the Operational provider generation and retained home
Gateway-DNS/home-DNS01/TLS-retention generations. `aws setup` later rotates/reconciles the same
identities explicitly; Sprint `7.33` adds the Operational AWS-run DNS01 generation. Ordinary
teardown removes only Operational key/IAM/Vault generations; exported-manifest `nuke` removes TLS
prefix objects/versions and its identity before the final Authority-backup/shared-bucket node.
ACME EAB values enter through a separate closed-schema external linear ingress under their own
`OperatorMaterialPermit`, never the AWS admin prompt or `config setup`; retained-home Transit custody
then restores them to a fresh selected Vault through attested one-shot Agent workers.
For retained SES, Provider/Pulumi owns only non-credential SES, S3, and DNS resources. A
backup-receipted `OperatorMaterialPermit` gives Credential Provisioner sole ownership of the
deterministic SMTP IAM identity, least-privilege policy, and bounded access-key family; ordinary
postflight retains that family. Credential Provisioner alone creates, rotates, or remints its
material and deletes uncommitted or unrecoverable keys during repair. On successful creation it
derives the region-bound closed `SesSmtpSource` in bounded memory, discards the raw AWS
secret-access-key bytes, and ingresses only that payload to retained-home Transit-sealed custody.
Later rebuilds use attested one-shot Agent-to-Agent rewrap without an admin re-prompt or IAM-key
rotation. Explicit `DestroyAwsSes` is the only exception: after consumers quiesce, Admin Action
Runner may delete/read back the entire registered external SMTP IAM family. Only then, while Agents
remain live, do `DestroyAwsSes` and `nuke` physically destroy every owned target/custody KV-v2
version, delete/read back its metadata, and prove absence. Soft delete or writing a new logical
tombstone is not teardown. Rotation preserves the current generation and physically destroys only
dependency-free superseded versions. Neither path is a generic secret export, and Admin Action
Runner may never create, rotate, or remint SMTP credentials.

### AWS Validation Stacks

Create or inspect the AWS validation stacks through these commands. The current binary still
hydrates its pre-cutover cluster-backed encrypted backend transport; the target submits a durable
provider operation to retained Lifecycle Authority, which owns the checkpoint reference and
bounded scratch hydration:

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
./.build/prodbox test integration charts-vscode
./.build/prodbox test integration charts-api
./.build/prodbox test integration charts-websocket
./.build/prodbox test integration admin-routes
./.build/prodbox test integration public-dns
./.build/prodbox test integration dns-aws
./.build/prodbox test integration aws-iam
./.build/prodbox test integration aws-eks
./.build/prodbox test integration pulumi
./.build/prodbox test integration ha-rke2-aws
./.build/prodbox test integration gateway-daemon
./.build/prodbox test integration gateway-pods
./.build/prodbox test integration gateway-partition
./.build/prodbox test integration charts-platform
./.build/prodbox test integration pulsar-broker
./.build/prodbox test integration keycloak-invite
./.build/prodbox test integration charts-storage
./.build/prodbox test integration eks-volume-rebind
./.build/prodbox test integration sealed-vault
./.build/prodbox test integration lifecycle
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
- run the supported local-runtime postflight; current-revision always-run restoration remains part
  of the reopened deployment-qualification work

These suites require the real tools, credentials, cluster state, DNS state, or AWS resources named
by their prerequisite contracts. A green current-revision aggregate is necessary but insufficient:
qualification also requires the frozen old/new counterexample, normalized resource mapping,
production envelope/load profile, complete fault matrix, consecutive runs, authoritative cleanup,
and digest-bound evidence artifact; see
[Development Plan Standard P](./DEVELOPMENT_PLAN/development_plan_standards.md#p-deployment-qualification-and-counterexample-closure).

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
- [Bootstrap Readiness Doctrine](./documents/engineering/bootstrap_readiness_doctrine.md)
- [Storage Lifecycle Doctrine](./documents/engineering/storage_lifecycle_doctrine.md)
- [Vault Secret-Management Doctrine](./documents/engineering/vault_doctrine.md)
- [Unit Testing Policy](./documents/engineering/unit_testing_policy.md)
- [Claude Code Patterns (CLAUDE.md)](./CLAUDE.md)
- [Agent Guidelines (AGENTS.md)](./AGENTS.md)
