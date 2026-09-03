# Prodbox

**Status**: Reference only
**Supersedes**: N/A
**Generated sections**: none

> **Purpose**: Project overview, operator guide, installation guide, and documentation index for
> `prodbox`.

Home Kubernetes cluster management with a Haskell CLI, a MetalLB + Envoy Gateway + Keycloak
public edge, and Pulumi-backed AWS validation stacks.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

## Overview

Prodbox is a Haskell-first repository for managing a home Kubernetes cluster and its AWS-backed
validation environments.

- Current sprint status and resume order live only in
  [DEVELOPMENT_PLAN/README.md → Resume Here](./DEVELOPMENT_PLAN/README.md#resume-here);
  per-sprint validation closure and cleanup/removal ownership remain in the plan suite, while stable
  target architecture is indexed
  by [documents/engineering/README.md](./documents/engineering/README.md).
- The authoritative CLI doctrine is distributed across per-surface engineering docs under
  [documents/engineering/](./documents/engineering/README.md): command topology,
  progressive introspection, and reconcilers in `cli_command_surface.md`; Plan / Apply
  and GADT-indexed state machines in `pure_fp_standards.md`; project structure,
  subprocesses, smart constructors, error handling, capability classes, retry policy, and
  application environment in `haskell_code_guide.md`; generated artifacts and lint stack
  in `code_quality.md`; output rules and at-least-once event processing in
  `streaming_doctrine.md`; prerequisites as typed effects in `prerequisite_doctrine.md`;
  operation-indexed readiness and current-authority kubelet admission in
  `bootstrap_readiness_doctrine.md`; the physical
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
- The **target** supported configuration contract is described by
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
  of the supported interface. The current binary still resolves the operator-authored
  binary-sibling `prodbox.dhall` directly; the exact pre-cutover correspondence is stated under
  [Configuration](#configuration), and rollout status remains plan-owned.
- The supported Pulumi scope is limited to the AWS validation stacks under `pulumi/aws-eks/`,
  `pulumi/aws-eks-subzone/`, `pulumi/aws-test/`, and `pulumi/aws-ses/`; local-cluster platform
  ownership does not use a root Pulumi project. The `prodbox` surface is the exclusive AWS mutation
  boundary. In the target lifecycle design, the CLI, validation harness, recovery flow, and
  explicit stack commands are peer clients of the registered lifecycle core and role-specific
  interpreters. The authoritative
  inventory and per-resource lifecycle class (per-run cleanup-managed stacks vs long-lived
  cross-substrate shared infrastructure vs K8s-controller-created cluster-tagged AWS) live in
  [DEVELOPMENT_PLAN/substrates.md → Resource Lifecycle Classes](./DEVELOPMENT_PLAN/substrates.md#resource-lifecycle-classes).
- Block storage is unified across substrates: every PV is a static, no-provisioner, `Retain`,
  deterministically-rebinding volume — a `hostPath` under `.data/` on the home substrate, a
  **pre-created EBS volume lifted in as a static `Retain` PV** (CSI `volumeHandle`, AZ-pinned) on the
  AWS/EKS substrate. There is no dynamic provisioning on either substrate. Production retains the EBS
  volumes exactly as it retains `.data/`; target lifecycle cleanup selects only statically
  test-scoped EBS at suite postflight and requires exact absence read-back before calling that
  obligation complete. An unobservable or failed EBS cleanup remains an incomplete result, never a
  “no leak” claim.
  Current code still represents both EBS policies under one `LongLived` registry identity and
  partitions reaper results by tags; the accepted target uses separate statically classified
  `PerRun` test and `LongLived` production identities before provider observation. See the
  [current-versus-target registry note](./DEVELOPMENT_PLAN/substrates.md#resource-lifecycle-classes).
  prodbox creates its own dedicated EKS VPC (never
  the account default), tags the VPC/IGW/route-table/subnets with `prodbox.io/managed-by=prodbox`
  for terminal escape-audit visibility, and the test harness always provisions a fresh test VPC. See
  [documents/engineering/storage_lifecycle_doctrine.md](./documents/engineering/storage_lifecycle_doctrine.md).
- Resource admission and containment are explicit: host capacity, RKE2 reservations, eviction floors,
  workload runtime-memory/service-demand/scratch/durable/topology inputs, and durable PVC capacities
  are part of the typed capacity plan, not template-local defaults. Request/limit envelopes are
  derived outputs, not independent configuration. Over-commitment is unrepresentable at
  the **Haskell decode gate**, not merely rejected before render: the host/cluster/workload nesting is
  an opaque proof-carrying `AllocatedResourcePlan` (module `Prodbox.Capacity.Allocation`) built by the
  total smart constructor `compileResourcePlan` — a sibling to the opaque proofs `ServiceCapacityPlan`
  and `RuntimeMemoryPlan`, with `Prodbox.Capacity.Derivation` as the sole workload-envelope builder.
  The proof is a required field of the validated settings every command carries,
  so a cluster that reserves more than the host has, a workload set that exceeds cluster allocatable
  capacity, or a chart container without a limit has no representation any command can consume (a `Left`,
  never a value); Dhall is a defense-in-depth generator cross-check (it has no refinement types, so this
  ring is not the guarantee — `prodbox config generate` bakes an over-commit `assert` into the generated
  `prodbox.dhall`, so an over-committed file fails to load), the host is re-proved at reconcile against
  observed facts, and `config generate` pre-fits `host_capacity` to the observed host, failing fast when
  it is too small (`--portable` keeps host-agnostic generation for the image build). A
  non-saturating `resourceVectorSubtractChecked` (an underflow returns `Left`, never clamps to zero)
  replaces the saturating budget subtraction, and a `GuaranteedEnvelope` witness makes `request == limit`
  a constructor invariant for Guaranteed-QoS workloads. Each workload's `durable_storage_mib` is the
  *one* value that sizes its PVC, its namespace `requests.storage` quota, and the fit proof, so a
  chart-local PVC size can never drift from the quota. Namespace `ResourceQuota` / `LimitRange` are
  derived projections of the workloads' actual draws (replicas × limit), not authored quotas — the
  hand-folded `namespace_quotas` type is retired for a typed `WorkloadConcurrency`
  (`Steady | ExclusiveWindow`) that models co-location and burst structurally. Invariant (b),
  `cluster <= host` (cpu/memory plus durable and ephemeral disk on distinct devices), is re-proved at
  `cluster reconcile` by compiling the plan against the observed host; runtime reconciliation then
  installs the matching RKE2/kubelet guardrails together with those derived `ResourceQuota` /
  `LimitRange` and the chart `resources` stanzas. The full model and its honest three-ring boundary
  live in [resource_scaling_doctrine.md](./documents/engineering/resource_scaling_doctrine.md);
  rollout and qualification status live in the
  [Development Plan](./DEVELOPMENT_PLAN/README.md). Those declarations do not by themselves prove an
  arbitrary program's peak working set. The nested runtime-memory plan, run-scoped
  restart/OOM/high-water oracle, measured calibration inputs, and remaining raw-envelope seam are
  described with their exact current/target boundary in
  [Measured Resource Profiles](./documents/engineering/resource_scaling_doctrine.md#2f-measured-resource-profiles);
  measurements never directly author or bless an envelope.
- A `LongLived` lifecycle class controls cleanup, not desired presence. When an invite-capable suite
  is selected, the target plan visibly reconciles the registered `aws-ses` stack through the
  retained home/control-plane Lifecycle Authority, awaits semantic SES readiness, then materializes
  the SMTP generation from its retained-home Transit-sealed custody through attested one-shot home
  and selected-substrate Agent workers. A fresh AWS Vault therefore does not require an admin
  re-prompt or key rotation; ordinary suite postflight destroys neither the stack nor that custody.
  See
  [DEVELOPMENT_PLAN/phase-4-lifecycle-canonical-paths.md](./DEVELOPMENT_PLAN/phase-4-lifecycle-canonical-paths.md)
  and [DEVELOPMENT_PLAN/phase-5-canonical-test-suite.md](./DEVELOPMENT_PLAN/phase-5-canonical-test-suite.md).
- Target lifecycle commands use fail-closed cleanup through an exact typed registry and authoritative
  read-back. `prodbox cluster delete --yes` remains deliberately local-only: it preserves `.data/`,
  leaves AWS untouched, and no-ops when RKE2 is absent. The target `--cascade` instead starts or
  resumes a durable recover-to-clean operation. It establishes the minimal teardown control plane
  when possible, observes each per-run resource independently, reconciles exact absence, audits for
  escapes when the exact projection contains AWS targets (otherwise using a typed no-AWS witness),
  commits the backed-up convergence report, and uninstalls local RKE2 last. Incomplete
  cleanup returns a stable `CleanupRunId` and the observed recovery-plane disposition; an
  established plane remains live. The global tag audit is defense-in-depth only; it cannot select a
  stack or prove one absent. `prodbox nuke` remains the operator-only total-decommission path. See
  [Lifecycle Reconciliation Doctrine](./documents/engineering/lifecycle_reconciliation_doctrine.md)
  and [Lifecycle Control-Plane Architecture §11.0](./documents/engineering/lifecycle_control_plane_architecture.md#110-ordinary-teardown-recovery-profile).
  Until the plan-tracked cutover lands, the current binary still uses the legacy handwritten
  cascade. A cascade with no local RKE2 installation reaches no phase and exits non-zero with a
  `RecoveryPlaneNotEstablished` disposition; local-only delete alone owns the no-install success
  arm. **Neither cascade exit code is exact AWS-absence evidence.** A non-zero cascade is unresolved,
  while zero still carries no exact completion receipt. Preserve `.data/` and the complete output
  for recovery in both cases, and treat deleting `.data/` as an action that needs a positive
  disposition of the capabilities it holds rather than a clean-looking exit. Rollout status lives only in
  [Development Plan → Resume Here](./DEVELOPMENT_PLAN/README.md#resume-here).
- This target edge doctrine has substrate-specific lower layers: the home substrate uses MetalLB,
  while the AWS substrate uses the AWS Load Balancer Controller/NLB path. Both substrates provision
  Envoy Gateway, Gateway API, cert-manager, and the same shared application/platform service set through their
  substrate-aware installers.
- The public-edge topology uses one validated served FQDN per substrate, with Keycloak on `/auth`,
  `vscode` on `/vscode`, the API on `/api`, the WebSocket workload on `/ws`, and the MinIO console
  on `/minio`. The home FQDN is operator-authored and fail-closed: generation leaves it empty,
  setup authors it, and validation retains the narrowed value with no compiled deployment host.
  Rollout status lives only in
  the [Development Plan](./DEVELOPMENT_PLAN/README.md#resume-here). The in-cluster registry has no
  web UI and therefore no public-edge route.
- The Haskell `prodbox gateway ...` command group and `charts reconcile gateway` manage the separate
  distributed gateway daemon; they are not the Envoy Gateway public edge controller.
- Vault is the fail-closed KMS, PKI, and post-unseal operational-secret root for every managed
  cluster. The only non-Vault secret classes are the bounded Tier-1 bootstrap transaction and an
  ephemeral operator prompt that is never persisted. Before first init, the transaction read-backs
  a password-AEAD `PreparedInitEnvelope`; it then retains Vault's PGP-encrypted init response until
  the final password-AEAD unlock bundle is atomically promoted and read back. The master-seed and
  Secret-mounted credential models are retired. Vault has retained storage, is initialized once,
  and is subsequently only unsealed/reconciled. Its initial root token is PGP-encrypted to a pinned
  burn public key whose private material existed only inside an isolated destructive ceremony,
  was never exported, was destroyed before adoption, is never accepted, retained, or available to
  `prodbox`, and has no known holder; that ciphertext is never decrypted or used. Bounded baseline work uses a
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
- **cert-manager** for listener TLS, rendering one ZeroSSL ACME `ClusterIssuer`. Each exact
  canonical certificate SAN set is retained under its own long-lived, substrate-scoped S3 key and
  restored before issuance evaluation, so rebuilds reuse that set without ordering again. Its
  `dnsNames` are a total projection of the operator-configured `CertScopeSet`
  (`domain.cert_scopes`), which defaults to the single served host; listeners/routes/DNS remain
  explicit served-host bindings and are never enumerated from wildcard SAN coverage. Host chart
  orchestration triggers retain/restore only through the closed Lifecycle Authority workflow;
  Authority alone authenticates to its TLS fold, ciphertext Adapter, and exact Target TLS routes
  (see
  [DEVELOPMENT_PLAN/README.md](./DEVELOPMENT_PLAN/README.md) and
  [acme_provider_guide.md → Configurable Certificate Scope](./documents/engineering/acme_provider_guide.md#5-configurable-certificate-scope))
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
[DEVELOPMENT_PLAN/README.md → Resume Here](./DEVELOPMENT_PLAN/README.md#resume-here) and its linked
phase/ledger records. Engineering docs under
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
  https://<configured-served-fqdn>/auth   -> Keycloak identity flow
  https://<configured-served-fqdn>/vscode -> Envoy-protected browser app
  https://<configured-served-fqdn>/api    -> JWT-protected API
  https://<configured-served-fqdn>/ws     -> JWT-protected WebSocket workload
  https://<configured-served-fqdn>/minio  -> MinIO console
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
  Its dedicated `bootstrap-broker start --config <path>` role uses one strict secret-free protocol
  and an exact operation-indexed engine; every Vault/store mutation additionally needs the current
  durable fence and Lease permits.
- Exactly one logical Lifecycle Authority in the retained home control plane owns durable
  operation IDs, authority epochs, fencing, checkpoints, provider revisions, credential
  generations, and target-delivery intents; the ephemeral AWS substrate receives a client
  reference, never a second writer.
- The retained local RKE2 control plane is mandatory for supported operation and remains the
  authority even when AWS is selected. AWS is an optional target substrate. If the local Authority
  or its exact worker/adapter path is unavailable, AWS-targeted commands fail closed; they never
  fall back to host-direct provider or Pulumi mutation.
- Physically separate Authority Backup and TLS Retention Adapters, the fenced Provider Worker,
  mode-indexed Credential Provisioner, and explicit Admin Action Runner each interpret only their
  closed capability program. The post-export Decommission Runner is outside the live control plane.
- A Target Secret Agent owns allowlisted payload sealing plus generation-checked Vault KV
  observe/CAS/read-back on one substrate and an exact TLS-Secret lane. The retained home Agent also
  owns payload-specific Transit-sealed custody/rewrap for the closed SMTP and ACME-EAB schemas, plus
  TLS DEK exchange. One-shot home/selected workers transfer only attestation-encrypted payloads;
  long-lived controllers receive ciphertext and typed receipts, never plaintext or a generic export.
- The Gateway Runtime owns mesh, ownership projection, its encrypted identity-bound local emitter
  journal and, on home only, the registered Gateway-DNS effect. One actor holds the whole
  stage/fsync/publish/commit/fsync transition; EKS Gateway DNS mutation is disabled.
- On EKS, Broker, Gateway diagnostics, and Target Secret Agent have distinct Service transports;
  Lifecycle Authority and the fenced Provider Worker remain in retained home RKE2. AWS provider
  work reaches that home-only worker only through registered Authority/Provider intents; no
  Provider Worker Service is deployed in EKS. Cert-manager receives only its run-scoped target
  Vault generation through a memory-only one-shot materializer. Deterministic EKS IAM names bind
  both run/stack and cluster identity for exact recovery and cleanup.
- Capability observation, admission, and execution use one operation-indexed `CapabilityRef` and one
  propagated absolute deadline.

The source contains the Broker role, protocol, custody journals, and deterministic runtime proof.
The current production facade serves liveness and fails closed for readiness and every non-health
request; the physical adapters and workload composition are not the active production path. Until
the plan-tracked replacement is qualified, the combined gateway implementation remains an explicit
[Standard-P](./DEVELOPMENT_PLAN/development_plan_standards.md#p-deployment-qualification-and-counterexample-closure)
rollback path.

The pure-functional types, interpreter boundaries, cutover invariants, and verification obligations
are authoritative in
[lifecycle_control_plane_architecture.md](./documents/engineering/lifecycle_control_plane_architecture.md).

### Current Implementation Baseline

The edge, chart, Vault, MinIO, and Haskell CLI surfaces remain available, but the current binary
still uses the gateway-backed lifecycle authority/readiness composition rather than the target
role-isolated control plane. Measured failure modes include CPU-throttled deep-readiness and retained
SES lease/release timeouts, mismatched authority observation/execution endpoints, and local chart
restoration that can remain incomplete after retained-resource failure. These current facts do not
constitute deployment qualification. The authoritative status, counterexample evidence, and
remaining-work ownership live in the
[Development Plan](./DEVELOPMENT_PLAN/README.md#resume-here); the stable replacement
boundaries live in
[Lifecycle Control-Plane Architecture](./documents/engineering/lifecycle_control_plane_architecture.md).

The measured-capacity recorder is available as
`prodbox test integration gateway-pods --record-profile`. It writes
`dhall/capacity/measured/gateway.dhall` only after a healthy 30-minute/300-sample window; committing
that first profile activates the existing gateway capacity-certification gate.

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

# The binary owns its config and resolves it beside the executable, so generate the
# binary-sibling Tier-0 file before anything else. Commands that need it fail fast when
# ./.build/prodbox.dhall is absent.
./.build/prodbox config generate

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
  Target Gateway routing contains no bootstrap handlers; only the isolated
  `LegacyModelBEmitter` rollback can reach the registered legacy adapter until qualification
  evidence authorizes cutover.

## Quick Start

Use this sequence for a first supported local bring-up:

```bash
cabal install exe:prodbox --builddir=.build --installdir=.build --install-method=copy --overwrite-policy=always

# Generate the binary-sibling Tier-0 prodbox.dhall first; `config setup` re-authors it
# interactively, but the file must exist before any command that reads it.
./.build/prodbox config generate

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
- The current `cluster reconcile` installs and reconciles the current RKE2 platform. The frozen,
  role-isolated Broker/Agent/Authority/Backup-Adapter genesis sequence is the target control-plane
  topology, not current behavior; its implementation and cutover are tracked in the
  [Development Plan](./DEVELOPMENT_PLAN/README.md#resume-here). The current command also
  installs the registry, MetalLB, Envoy Gateway, cert-manager, and the Percona PostgreSQL operator.
- `charts reconcile vscode` deploys the `vscode` stack plus its supported dependencies:
  `keycloak` and the internal `keycloak-postgres` Patroni release, with the browser path protected
  by Envoy Gateway and Keycloak on the shared `/auth` path.
- `charts reconcile api` deploys the shared-host API workload on `/api`.
- `charts reconcile websocket` deploys the shared-host WebSocket workload plus its internal Redis
  dependency on `/ws`.
- `edge status` confirms Route 53, Envoy Gateway, Gateway API, and certificate readiness for
  the shared browser, API, WebSocket, and MinIO edge paths (the public edge uses the
  single ZeroSSL ACME issuer with retained-and-restored certificate material; see
  [acme_provider_guide.md](./documents/engineering/acme_provider_guide.md)). It also reports a
  `CERTIFICATE_EXPIRY=<rung>` line — a fail-closed rung observed from cert-manager
  `status.renewalTime`/`notAfter` with no repo-side renewal-window recompute
  (`certificate-current` / `certificate-renew-due` / `certificate-expired` /
  `certificate-unobservable`; see
  [envoy_gateway_edge_doctrine.md → Diagnostics and Validation Doctrine](./documents/engineering/envoy_gateway_edge_doctrine.md#11-diagnostics-and-validation-doctrine)).
- `charts reconcile gateway` reconciles the separate mesh/DNS Gateway Runtime and is not required
  to bring up the Envoy Gateway public edge. Bootstrap Broker, Lifecycle Authority, and Target
  Secret Agent are distinct control-plane components in the target cluster plan, not gateway
  modes.

## Configuration

All supported configuration is Dhall decoded in-process by the native Haskell `dhall` library. The
current host CLI resolves the binary-sibling `prodbox.dhall`; cluster workloads consume their
mounted Dhall projections. The immutable Vault-Transit-enveloped config selected by a
schema/digest/reference/generation in the Lifecycle Authority aggregate, with the sibling file used
only as a seed/propose input, is the target authority model and is not yet the active production
path. The complete current/target sourcing and decryption contract lives in
[documents/engineering/config_doctrine.md](./documents/engineering/config_doctrine.md); rollout
status lives only in the [Development Plan](./DEVELOPMENT_PLAN/README.md#resume-here).

Configuration has three tiers: non-secret binary bootstrap context, password-gated Vault recovery
material, and Vault-gated operational secrets/encrypted state. Their exact contents, paths,
generation rules, and bootstrap protocol are defined only in
[config_doctrine.md §0](./documents/engineering/config_doctrine.md#0-three-tier-config-model).

Before those secrecy tiers, every value has exactly one ownership. Deployment-varying values —
the served FQDN and ACME contact, cluster/topology identity, service endpoints, and AWS
region/network/resource envelope — are authored in Tier-0 or explicitly derived for a test run and
have no Haskell fallback. Protocol-fixed and prodbox-chosen identities — such as the ZeroSSL
directory and prodbox's object, stack, namespace, IAM, and Vault-path names — are declared once in
code and are not exposed as ignored config fields. The exact partition and current gaps are owned by
[config_doctrine.md §0](./documents/engineering/config_doctrine.md#compiled-protocol-constants-versus-operator-supplied-deployment-values).

Every instance-config or secret-fixture `.dhall` file is generated or locally authored and
git-ignored: the binary-sibling `prodbox.dhall`, the generated
`prodbox-config-types.dhall` / `test-secrets-types.dhall` schemas, and `test-secrets.dhall`. Five
schema/golden `.dhall` artifacts under `dhall/` and `test/golden/` are version-controlled by design;
they are not instance configuration. There is **no committed container
default** — the in-container `prodbox.dhall` is generated at image-build time by running the
binary (`prodbox config generate`) at the binary-sibling path, never a `COPY`-ed
`default-prodbox.dhall` (Sprint 1.49). In the target authority model, the binary-sibling
`prodbox.dhall` is the seed/propose input for Lifecycle Authority; in both current and target forms
it carries no plaintext secrets, only non-secret topology and role/capability coordinates. See
[config_doctrine.md §0](./documents/engineering/config_doctrine.md#0-three-tier-config-model).

- `prodbox config setup` writes and validates Dhall directly.
- `prodbox config show` renders the decoded Haskell settings model, masking secrets by default.
- `prodbox config validate` verifies the required fields and binding rules.
- No supported command materializes `prodbox-config.json` or any other JSON projection.
- No supported `prodbox` binary reads `PRODBOX_*` environment variables for runtime
  configuration. Startup-time config resolution differs by binary, and the difference is
  load-bearing:
  - the **host CLI** has no `--config` flag at all. It resolves the Tier-0 `prodbox.dhall` sitting
    beside the executable, and fails fast when that sibling file is absent.
  - the **in-cluster daemon and workloads** read their mounted Dhall through `--config <path>`.
- The current `prodbox config show --show-secrets` flag is pre-cutover legacy tracked in the
  [removal ledger](./DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md). Target `ConfigObserve`
  returns only a role-scoped, validated projection and has no generic secret-reveal capability.

The test harness regenerates its disposable binary-sibling `prodbox.dhall` through the production
config builder. `test-secrets.dhall` supplies externally chosen non-secret deployment inputs such
as the served FQDN and ACME contact alongside its test-only secrets. A validated
`prodbox.test.dhall` variant supplies cluster topology plus Vault/MinIO endpoints; stable
suite/variant identity derives the ephemeral cluster id and repository-relative `.test-data` root.
The legacy aggregate carries equivalent explicit fixture fields until its topology cutover. Both
lanes refuse incomplete input before credential acquisition or infrastructure preparation,
validate the complete config/context before one atomic Tier-0 write, and never overwrite a
complete operator-authored sibling. See
[Test Topology Doctrine §3](./documents/engineering/test_topology_doctrine.md#3-test-run-drives-the-real-deploy-path-across-every-variant).

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

The wizard authors and validates only the non-secret binary-sibling Tier-0 boot/proposal
coordinates (`./.build/prodbox.dhall`), including the served FQDN, ACME contact, cluster and
machine identities, Vault address, MinIO endpoint, and Route 53 choices. `config generate` instead
emits an intentionally unauthored skeleton, and no consuming settings/context can be built until
the required deployment coordinates are supplied. Credentialed effects
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
| `domain.demo_fqdn` | Primary public FQDN; there is no compiled deployment hostname |
| `context.cluster_id` | Deployment cluster identity |
| `cluster_topology.machines[].machine_id` | One or more deployment machine identities on the home substrate |
| `context.vault_address` | Vault endpoint URL |
| `context.minio_endpoint` | MinIO endpoint URL |
| `aws.region` | Operational AWS region. `prodbox config generate` emits it **empty**, like every other operator-owned coordinate, so an AWS flow refuses by name until you supply it — run `prodbox aws setup`, which the refusal names. There is no compiled fallback, and the admin-credential prompt offers no pre-filled region when the config carries none |

### Operationally Important Fields

These fields are not all parser-required, but they matter for normal operation:

| Config Path | Description |
|-------------|-------------|
| `deployment.public_edge_advertisement_mode` | Optional MetalLB advertisement mode: `l2` or `bgp` |
| `deployment.envoy_gateway_controller_scaling` | Envoy Gateway controller scaling policy, per substrate (`home_local`, `aws`), each `Fixed n` or `Elastic {min,max}` |
| `deployment.envoy_gateway_data_plane_scaling` | Envoy data-plane scaling policy, same shape |
| `deployment.api_scaling` | API workload scaling policy, same shape |
| `deployment.websocket_scaling` | WebSocket workload scaling policy, same shape |
| `storage.manual_pv_host_root` | Host root reserved for retained PV contents; defaults to `.data` under the repo |

### Optional Fields

| Config Path | Description |
|-------------|-------------|
| `domain.demo_ttl` | DNS TTL in seconds |
| `domain.cert_scopes` | Optional list of public-edge certificate scopes (exact hosts or `*.zone` wildcards, wildcards only at a config-delegated zone). Empty (default) means exactly the served host, so the public-edge certificate covers one FQDN until an operator widens scope. See [acme_provider_guide.md → Configurable Certificate Scope](./documents/engineering/acme_provider_guide.md#5-configurable-certificate-scope) |
| `deployment.bootstrap_public_ip_override` | Bootstrap-only DNS A-record IP override |
| `deployment.pulumi_enable_dns_bootstrap` | Bootstrap toggle for DNS reconciliation during the supported flow |
| `deployment.public_edge_bgp_peers` | Optional BGP peer list when `deployment.public_edge_advertisement_mode = Some "bgp"` |

There is no `acme.server` or state-bucket field. ZeroSSL is the one supported ACME provider and its
directory URL is a compiled protocol identity; `prodbox-state` is the single compiled generic
object-store identity. Both remain fixed while operator-authored deployment coordinates vary.

The current decoder still accepts the pre-cutover root `aws.session_token` field alongside the
shared access-key fields named above. It is not part of the target role-scoped configuration and is
tracked for removal in the
[legacy ledger](./DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md); new design work must not add
consumers.

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
| Local cluster lifecycle | `cluster reconcile`, `cluster status`, `cluster health`, `cluster start`, `cluster stop`, `cluster restart`, `cluster logs`, `cluster wait`, `cluster workload-logs`, `cluster delete --yes`, `cluster delete --cascade`, `nuke` | Create, reconcile, inspect, or remove RKE2. Local-only delete preserves retained roots and does not touch AWS. The target cascade resumes a durable recover-to-clean run and uninstalls locally only after backed-up exact absence evidence; see the current-implementation warning above. `nuke` is the operator-only decommission command; its complete total-decommission contract is also a plan-tracked target. |
| Chart lifecycle | `charts list`, `charts status`, `charts reconcile`, `charts delete --yes` | You need to manage the supported `gateway`, `keycloak`, `vscode`, `api`, or `websocket` chart stacks |
| Bootstrap Broker runtime | `bootstrap-broker start --config <path>` | You need to validate or launch the dedicated pre-Vault controller role. The code-local production boundary is fail-closed except for liveness until its physical adapters/workload land; `--dry-run` validates and renders the secret-free plan without starting the listener |
| Gateway operations | `gateway config-gen`, `gateway start --config <path>`, `gateway status --config <path>` | You need to generate a gateway config, run a daemon manually, or inspect daemon state |
| DNS | `dns check` | You need Route 53 inspection for the configured public host |
| AWS IAM and quotas | `aws policy`, `aws setup`, `aws teardown`, `aws quotas check`, `aws quotas request` | You need IAM bootstrap, cleanup, or supported quota inspection/request flows |
| AWS validation stacks | `aws stack eks reconcile`, `aws stack eks destroy --yes`, `aws stack aws-subzone reconcile`, `aws stack aws-subzone destroy --yes`, `aws stack test reconcile`, `aws stack test destroy --yes`, `aws stack aws-ses reconcile`, `aws stack aws-ses destroy --yes` | You need to create, inspect, or destroy the AWS EKS, Route 53 subzone, HA-RKE2, or SES validation stacks (see [DEVELOPMENT_PLAN/substrates.md → Resource Lifecycle Classes](./DEVELOPMENT_PLAN/substrates.md#resource-lifecycle-classes) for per-run cleanup versus intentional retention) |
| Vault | `vault status`, `vault init`, `vault unseal`, `vault seal`, `vault reconcile`, `vault rotate-unlock-bundle`, `vault rotate-transit-key`, `vault pki ...` | You need to initialize, unseal, seal, or reconcile the in-cluster Vault that backs cluster secrets. Bounded bootstrap leaves use the exact Bootstrap Broker capability and post-unseal work uses least-privilege Vault interpreters; the former combined Gateway and host-direct lifecycle routes are removed and guarded by source/route lints (see [vault_doctrine.md](./documents/engineering/vault_doctrine.md#7-vault-lifecycle-commands)) |
| Lifecycle control-plane roles | `lifecycle-authority start`, `provider-worker start`, `authority-backup start`, `tls-retention start`, `target-secret-agent start`, `admin-action run`, `credential-provisioner run`, `credential-provisioner target-worker`, `bootstrap-broker secret-worker`, `workload start` | You need to run one of the in-cluster control-plane role processes described under [Target Architecture](#target-architecture). Each takes its mounted Dhall through `--config <path>`; none is an operator-interactive command |
| Users and federation | `users invite`, `users list`, `users revoke`, `cluster federation register` | You need to manage operator-invited Keycloak identities, or register a child cluster against its parent |
| Validation | `dev check`, `dev lint {all,files,docs,haskell,chart}`, `dev docs {check,generate}`, `test lint`, `test unit`, `test integration ...`, `test all`, `dev tla-check` | You need quality gates, generated-doc maintenance, Haskell tests, native integration validation, or TLA+ checks |

This table is a navigational summary, not the command surface. The complete, generated leaf-command
registry is [documents/cli/commands.md](./documents/cli/commands.md), rendered from the typed parser
so it cannot drift from what the binary accepts; `prodbox --help` and the installed manpages are the
same source.

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
ordinary local/cascade delete never removes `.data/`. The target separately authorized, TTY-only
`prodbox nuke` total-decommission path may remove it after external receipt export; the current
decommission graph does not yet include home uninstall or `.data` disposition, and its final tag
audit still runs outside the external receipt. A normal cluster rebuild is therefore not
a fresh Vault: `vault init` runs exactly once (the first time the PV is empty) and every later
`cluster reconcile` only unseals the existing data, so Vault KV is as durable across rebuilds as
any retained PV. Invoking local-only `cluster delete --yes` when no RKE2 installation exists is a
no-op success (`No RKE2 cluster to delete.`, exit 0). `cluster delete --cascade --yes` does not take
that shortcut, because local absence says nothing about durable cleanup or AWS: with no install
present it reaches no phase, names the durable cleanup run namespace it could not reach and the
`RecoveryPlaneNotEstablished` disposition it reports, makes no statement about per-run AWS stacks,
and exits non-zero. **No cascade exit authorizes deleting the retained root.** Only a `cluster
delete` terminal arm carrying a completion receipt, or an explicit local-only uninstall, says the
retained root is preserved by what it did; every other arm names the root and states that the run
establishes nothing about retiring it.

Consequences of that preservation are tracked in the development plan rather than described here.
Preserving `.data/` also preserves the Bootstrap Broker's session fence. A bring-up abandoned partway
therefore leaves that object behind, and `cluster delete --cascade` does not clear it — by design,
since the same tree holds the per-run Pulumi state. **That no longer wedges the host**: a predecessor
whose durable deadline has positively elapsed on a trusted clock is now retired and taken over,
provided its Kubernetes Lease is also absent or expired and its worker Pod is proven gone. Any of
those three facts being unreadable still refuses, so the takeover is never granted on ambiguity, and
the retirement itself is what revokes the predecessor's authority — every Vault effect re-reads the
fence immediately before acting.

The same tree preserves the Bootstrap Broker's durable **secret-worker checkpoint**, and that had the
same consequence one step further along the bring-up: a checkpoint written by an earlier invocation
could never match a later one, because the fence generation, the owner nonce, and the operation
deadline are all minted per invocation by construction. **That no longer wedges the host either.** A
checkpoint that carries no receipt and no result, and whose fence generation is strictly older than
the one now held, is discarded and rolled to a freshly allocated request — the predecessor's worker
being destroyed by a UID-preconditioned delete rather than assumed gone. A checkpoint carrying a
receipt is never discarded on any binding: that one is a record of work that already happened, and
its cleanup binding names a session no successor can reconstruct.

The target cascade treats a stopped or missing local API as recovery work. It repairs or reinstalls
only the minimal teardown profile against the preserved roots, resumes the durable cleanup run,
and records whether that profile was established, failed to establish, or was later lost. When it
was established, the profile remains live if exact cleanup cannot yet complete. The operator
receives the stable `CleanupRunId`; a retry resumes rather than reconstructing intent from prose or
tag scans.

That repair reads bytes only from a versioned, architecture-specific retained artifact inventory. A
recovery has no in-cluster image Registry to pull from and may not fetch an installer over the
network, so a repair whose inventory does not cover the observed state refuses and names every
missing artifact rather than falling back. Ordinary `cluster reconcile` is unaffected: it still
installs RKE2 the usual way. The distinction is that a recovery running while the platform is down
gets no ambient authority. This behavior is not yet the current binary behavior; see the warning in the Overview. See
[DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md](DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md)
for both, and
[DEVELOPMENT_PLAN/README.md](DEVELOPMENT_PLAN/README.md#resume-here) for their owning
sprints; this guide does not maintain a competing status ledger.

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
contract. The report also carries a separate `CERTIFICATE_EXPIRY=<rung>` line — a fail-closed
observation of the cert-manager `Certificate`'s committed `status.renewalTime`/`notAfter`
(`certificate-current` / `certificate-renew-due` / `certificate-expired` /
`certificate-unobservable`), with no repo-side renewal-window recompute; renewal itself stays
cert-manager's and ZeroSSL's alone (see
[envoy_gateway_edge_doctrine.md → Diagnostics and Validation Doctrine](./documents/engineering/envoy_gateway_edge_doctrine.md#11-diagnostics-and-validation-doctrine)).

### Bootstrap Broker Runtime

Validate the dedicated role-only config and inspect its secret-free plan:

```bash
./.build/prodbox bootstrap-broker start \
  --config /etc/bootstrap-broker/config/config.dhall \
  --dry-run
```

The command has no Gateway-config, binary-sibling, or environment fallback. An APPLY process binds
only its validated loopback listener; the current facade reports liveness but refuses readiness and
every non-health request. This is not a replacement-deployment or cutover claim.

The [Bootstrap Broker contract](./documents/engineering/lifecycle_control_plane_architecture.md#7-bootstrap-broker)
permits `Stopped` only after the accept thread and every worker join, all replay
waiters receive a terminal result, and queue/active/idempotency residue is empty. A join deadline
means `ShutdownIncomplete`; it is not permission to report `Stopped`.

### Gateway Operations

Generate a gateway config and inspect a daemon:

```bash
./.build/prodbox gateway config-gen gateway.dhall --node-id node-a
./.build/prodbox gateway start --config gateway.dhall
./.build/prodbox gateway status --config gateway.dhall
```

`gateway status` queries the daemon's HTTP `/v1/state` endpoint on the configured REST port. The
state route is the deep-diagnostics surface. Kubelet-facing readiness is a separate constant-time
projection over drain phase, emitter authority, and workers. The rollback topology latches validated
continuity startup. The public `gateway start` command still selects that mutually exclusive
`LegacyModelBEmitter` rollback topology; there is no operator switch or dual-write path. Target
Gateway registry/client/actor dispatch contains no bootstrap handlers; the rollback reaches only
the separately registered `LegacyAdapter`. The code-local `JournalLeaseEmitter` target requires its
current journal lock, matching Lease witness, and exact recovery for readiness, and returns to
`starting` on Lease loss until recovery succeeds. Physical workload consumption and public cutover
remain governed by the deployment-qualification record in
[DEVELOPMENT_PLAN/README.md](./DEVELOPMENT_PLAN/README.md#deployment-qualification).
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

**Target AWS authority flow (not current).** The governed `aws ...` flow prompts for an ephemeral
temporary admin credential only after
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
identities explicitly; the target set also contains the Operational AWS-run DNS01 generation. Ordinary
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
preserves `.data/`; test cleanup surfaces alone select test-scoped EBS. The current reaper performs
that partition by tags under one registry identity; the target uses the two static identities linked
above. Cleanup reports success only after exact absence read-back, while a partial or unobservable
result remains incomplete. See
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

The four commands above are **separate surfaces, not redundant ones**. `dev check` formats and lints
`app src test` and type-checks all of it, but type-checking is not running: a suite that compiles
still has to be executed to prove anything. Run all four before calling a change validated. Which
components that build actually selects — the *region* of the guarantee — is owned by
[resource_scaling_doctrine.md](./documents/engineering/resource_scaling_doctrine.md) under "The
region of Ring 2", along with the outage that established the rule. This guide states the operator
instruction and links the measurement rather than restating it; a restated measurement is how one
stale fact previously outlived its correction in two documents at once.

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
./.build/prodbox test integration certificate-scope
./.build/prodbox test integration clean-room-handoff
./.build/prodbox test integration charts-platform
./.build/prodbox test integration pulsar-broker
./.build/prodbox test integration keycloak-invite
./.build/prodbox test integration charts-storage
./.build/prodbox test integration eks-volume-rebind
./.build/prodbox test integration sealed-vault
./.build/prodbox test integration lifecycle
```

`certificate-scope` opens the real public HTTPS endpoint, verifies the TLS chain and hostname,
then compares the presented DNS SANs with the exact canonical `CertScopeSet`; cert-manager Ready
status by itself is not serving evidence.

`clean-room-handoff` renders the versioned authority-cutover/restore/cleanup trace, verifies that
interruption resumes only the exact next boundary, and runs the retired lifecycle-transport absence
guards through the installed binary.

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
- run the supported local-runtime postflight; exact current-revision cleanup behavior is recorded in
  the Development Plan

The target moves generic cleanup into the lifecycle-owned durable graph and makes `TestRunner` its
client: independent/`RequiresAttempt` work continues and all failures aggregate instead of
disappearing behind a fail-fast fold. This is not current-binary behavior; implementation and
cutover status live in
[DEVELOPMENT_PLAN/README.md → Resume Here](./DEVELOPMENT_PLAN/README.md#resume-here).

These suites require the real tools, credentials, cluster state, DNS state, or AWS resources named
by their prerequisite contracts. A green current-revision aggregate is necessary but insufficient:
qualification also requires the frozen old/new counterexample, normalized resource mapping,
production envelope/load profile, complete fault matrix, consecutive runs, authoritative cleanup,
and digest-bound evidence artifact; see
[Development Plan Standard P](./DEVELOPMENT_PLAN/development_plan_standards.md#p-deployment-qualification-and-counterexample-closure).

### Substrate Independence (No Fallback)

The canonical test suite is composed of per-substrate runs against both supported substrates —
the home local substrate and the AWS substrate. A complete canonical-suite proof requires both
runs to land independently against their own target application/platform infrastructure (DNS,
TLS via cert-manager, ingress, charts, public-edge proofs). Each run is substrate-locked: it
targets exactly one workload substrate, consumes only that target's operator-supplied config, and
fails fast if required target config is missing. There is no silent fallback from AWS target
values to home workload values or vice versa. Every AWS run additionally consumes the mandatory
retained-home Lifecycle Authority and Provider Worker; those are control-plane dependencies, not
target-config fallback. The two targets stand up the same application/platform service set and
block-storage discipline (static `Retain` no-provisioner PVs, deterministic rebinding), differing
within that projection only in ingress load-balancer, Route 53 hosting, and PV volume source
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

The list above is a starting point, not the index. `documents/engineering/` holds 40 governed
documents; [its README](./documents/engineering/README.md) is the complete one, and this file
deliberately does not maintain a second copy of it
([documentation_standards.md § 1](./documents/documentation_standards.md)). The ones most often
reached for and not listed above:

- [Config Doctrine](./documents/engineering/config_doctrine.md) — the three-tier model, the
  binary-sibling Tier-0 file, and the encrypted in-force object.
- [Chaos Hardening Doctrine](./documents/engineering/chaos_hardening_doctrine.md) — the
  concurrency-hardening methodology, and § 21's eight coordinates a decision needs on the value it
  decides from.
- [Pure FP Standards](./documents/engineering/pure_fp_standards.md) — purity boundary, GADT rules,
  Plan/Apply.
- [Resource Scaling Doctrine](./documents/engineering/resource_scaling_doctrine.md) — the capacity
  budget and the three enforcement rings.
- [Haskell Code Guide](./documents/engineering/haskell_code_guide.md) — subprocesses, smart
  constructors, capability classes, retry policy.
- [Prerequisite Doctrine](./documents/engineering/prerequisite_doctrine.md) — prerequisites as
  typed effects.
- [Host Platform Doctrine](./documents/engineering/host_platform_doctrine.md) — the host substrate
  is detected, never configured.
- [Generated CLI command registry](./documents/cli/commands.md) — every leaf command, rendered from
  the typed parser rather than transcribed.

### Target retained SES workflow (not current)

In the target topology, SES reconciliation is revisioned and crash-resumable through the retained
Lifecycle Authority.
Provider mutation owns no SMTP credential resources; the Credential Provisioner is the sole SMTP
IAM writer, and retained-home custody delivers generation-bound SMTP material independently to the
home or AWS Target Agent. Ordinary test postflight retains this long-lived aggregate. Its explicit
destruction remains `prodbox aws stack aws-ses destroy --yes`, executed through the governed
`DestroyAwsSes` dependency graph.

### Deployment qualification

Qualification requires
independent green `prodbox test all` and `prodbox test all --substrate aws` governed artifacts with
the complete invite assertions, mandatory fault campaign, exact backup restore, cleanup-owner
takeover, retained-generation restoration, and authoritative cleanup evidence.

Per-substrate qualification status and its evidence live in exactly one place — the
[Deployment Qualification ledger](./DEVELOPMENT_PLAN/README.md#deployment-qualification) — and this
file deliberately does not restate it.
