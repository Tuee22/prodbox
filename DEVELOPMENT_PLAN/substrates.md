# Test Suite Substrates

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md),
[development_plan_standards.md](development_plan_standards.md),
[00-overview.md](00-overview.md),
[system-components.md](system-components.md),
[phase-1-runtime-cli-aws-foundations.md](phase-1-runtime-cli-aws-foundations.md),
[phase-2-gateway-dns.md](phase-2-gateway-dns.md),
[phase-3-chart-platform-vscode.md](phase-3-chart-platform-vscode.md),
[phase-4-lifecycle-canonical-paths.md](phase-4-lifecycle-canonical-paths.md),
[phase-5-canonical-test-suite.md](phase-5-canonical-test-suite.md),
[phase-6-clean-room-handoff.md](phase-6-clean-room-handoff.md),
[phase-7-aws-substrate-foundations.md](phase-7-aws-substrate-foundations.md),
[phase-8-email-invite-auth.md](phase-8-email-invite-auth.md),
[the engineering doctrine docs](../documents/engineering/README.md),
[../documents/engineering/lifecycle_control_plane_architecture.md](../documents/engineering/lifecycle_control_plane_architecture.md),
[../documents/engineering/acme_provider_guide.md](../documents/engineering/acme_provider_guide.md),
[../documents/engineering/vault_doctrine.md](../documents/engineering/vault_doctrine.md),
[../documents/engineering/lifecycle_reconciliation_doctrine.md](../documents/engineering/lifecycle_reconciliation_doctrine.md),
[../documents/engineering/resource_scaling_doctrine.md](../documents/engineering/resource_scaling_doctrine.md),
[../documents/engineering/cluster_topology_doctrine.md](../documents/engineering/cluster_topology_doctrine.md)
**Generated sections**: resource-lifecycle-classes, stack-command-surface

> **Purpose**: Inventory the substrates against which the canonical test suite runs, the
> provision and teardown surface each substrate owns, and the current parity status of each
> substrate against the canonical suite.

> **Authoritative Reference**:
> [development_plan_standards.md → M. Test Suite Substrates](development_plan_standards.md#m-test-suite-substrates)

## Doctrine

The canonical test suite is the named-validation set in `src/Prodbox/TestValidation.hs`,
planned by `src/Prodbox/TestPlan.hs`, orchestrated by `src/Prodbox/TestRunner.hs`, and gated by
the prerequisite DAG in `src/Prodbox/Prerequisite.hs`. The suite is substrate-agnostic.

A substrate is an environment that, for the lifetime of a suite run, stands up the same set of
DNS records, TLS certificates (real ZeroSSL via cert-manager), ingress (Envoy Gateway plus
MetalLB or the substrate-equivalent), services, and workload charts; provides the prerequisites
declared in `src/Prodbox/Prerequisite.hs`; and is torn down on suite exit. Substrate lifecycle is
provision → run canonical suite → teardown.

The target lifecycle-control-plane topology is
[Lifecycle Control-Plane Architecture](../documents/engineering/lifecycle_control_plane_architecture.md):
a minimal Bootstrap Broker owns pre-Vault recovery, one retained Lifecycle Authority owns durable
operations and Model-B authority state, each substrate owns a Target Secret Agent, and the Gateway
Runtime owns mesh/ownership/DNS only. Those are distinct service identities and resource domains;
component labels or a successful call through a different endpoint are not readiness evidence.

## Substrate Independence (No Fallback)

The canonical test suite is composed of per-substrate runs against **both** supported
substrates listed below. A canonical-suite proof is complete only when both per-substrate runs
have been exercised. A run that exercises only one substrate covers only that substrate's row
in the parity table; the other substrate remains suite-incomplete until its own run lands.

Each per-substrate run is independent and substrate-locked: it targets exactly one substrate,
consumes only that substrate's operator-supplied config (`Required Config` row in each
substrate's table) and provisioned infrastructure, and fails fast if any required field is
missing. There is no silent substitution of home-substrate values for missing AWS-substrate
config, and no silent substitution of AWS values for missing home config. The substrate-aware
helpers `substratePublicFqdn` and `substrateHostedZoneId` in
`src/Prodbox/PublicEdge.hs` (alongside `Prodbox.Infra.AwsEksTestStack.withEksKubeconfig`
for substrate-aware kubeconfig materialization), together with the prerequisite DAG and
the lifecycle gates, enforce this contract.

See
[development_plan_standards.md → M. Substrate coverage and independence (no fallback)](development_plan_standards.md#substrate-coverage-and-independence-no-fallback)
for the authoritative doctrine.

## Substrate Coverage Is Orthogonal to Phase Closure

Substrate coverage of a suite validation is tracked **here, in the parity table and the
coverage notes below — never as a phase blocker.** Per
[development_plan_standards.md → N. Phase Independence](development_plan_standards.md#n-phase-independence-no-backward-blocking)
and
[O. Code-Local vs Live-Infra Proof](development_plan_standards.md#o-code-local-completion-vs-live-infra-proof)
(and the [M](development_plan_standards.md#m-test-suite-substrates) amendment), a
suite-content sprint is Done once its validation exists and passes on the **home
substrate**; the AWS-substrate run of that same validation is the AWS substrate's
**owned surface** (phase 7 provisioning) and is recorded as a parity-table coverage row,
not as a `Blocked by` on the suite-content sprint or its phase. An incomplete or
pending AWS-substrate coverage row never marks the home-substrate suite-content sprint,
or its phase, ⏸️ Blocked, and never reopens it.

Where an AWS-substrate coverage row needs live infrastructure that is not yet stood up
(live AWS spend, a deployed EKS cluster, an unsealed in-cluster Vault, an
operator-supplied credential), that row carries a **`Live-proof: pending`** note — a
distinct, non-blocking axis per Standard O. `Live-proof: pending` is not ⏸️ Blocked: it
gates neither the suite-content sprint's code-owned closure nor any earlier phase. The
home-substrate suite-content closure and the AWS-substrate coverage proof are separate
axes; the parity table is the single place the AWS axis is tracked.

The defers-to SSoT for this orthogonality is
[development_plan_standards.md → N / O](development_plan_standards.md#n-phase-independence-no-backward-blocking);
the substrate-coverage application of it lives in this file's parity table and coverage
notes.

Phase closure is not deployment qualification. Under
[Standard P](development_plan_standards.md#p-deployment-qualification-and-counterexample-closure),
the home and AWS target topologies remain **unqualified** until the exact current secret-safe
`SourceIdentity`, recorded/digested source-manifest exclusion-policy version, non-secret generated-
config identity, authored resource envelopes, required consecutive aggregates, fault matrix, and
cleanup observations are recorded as `proven` in
[README.md → Deployment Qualification](README.md#deployment-qualification). Historical green
runs remain evidence only for the topology and revision they exercised.

## Substrate Equivalence (Structural Invariant)

The home local substrate and the AWS substrate stand up the **same set of services**. As of
Sprint `7.12` this is a *structural* invariant, not prose, enforced by three mechanisms in code:

1. **One pinned Envoy Gateway release.** `Prodbox.ContainerImage.envoyGatewayRelease` pins the
   Envoy Gateway Helm chart version, the control-plane (gateway controller) image, and the
   data-plane (Envoy proxy) image together. Both installers consume it for all three pinning
   sites, so the EG-`1.4.4`-chart / Envoy-`1.37`-data-plane skew (audit C79) is eliminated by
   construction — there is no second place to set an Envoy Gateway version. cert-manager, MinIO,
   and the Percona operator chart versions are likewise pinned once in `Prodbox.ContainerImage`.
2. **A per-substrate re-pin lint.** `checkSubstrateImagePinning` (in `Prodbox.CheckCode`, wired
   into `prodbox dev check`) fails closed on any shared-component chart-version / image
   re-pinned with a literal on a per-substrate branch; the single `Prodbox.ContainerImage` value
   is the only sanctioned source. The genuinely substrate-specific LOWER layer (the AWS Load
   Balancer Controller on AWS, MetalLB + FRR on home, the EKS node-local registry proxy) is
   exempt — those have no cross-substrate counterpart to keep in lockstep.
3. **A shared `[PlatformComponent]` inventory + coverage test.**
   `Prodbox.ContainerImage.sharedPlatformComponents` declares the shared set once (`gateway`,
   `keycloak`, `keycloak-postgres`, `vscode`, `api`, `redis`, `websocket`, MinIO, the in-cluster
   registry (`registry:2`), the
   Percona operator, Envoy Gateway, cert-manager, ZeroSSL DNS01, and an in-cluster Vault). A
   `test/unit/Main.hs` coverage
   test asserts both installers (`homeSubstratePlatformComponents` in `Prodbox.CLI.Rke2`,
   `awsSubstratePlatformComponents` in `Prodbox.Lib.AwsSubstratePlatform`) cover every entry. It
   is **not** a unified step DAG — each substrate keeps its own ordering and its own lower-layer
   implementation — but neither installer may silently drop a shared component.

Sprints `3.26` and `7.33` expand that typed shared inventory and its coverage test with the
Bootstrap Broker and substrate-local Target Secret Agent. Until those implementation sprints land,
the existing generated/current registry remains historical implementation truth; Standard-P
status is recorded only in [README.md](README.md#deployment-qualification). The retained Lifecycle Authority is intentionally not duplicated
in that per-substrate list: it is one cross-substrate control-plane dependency hosted by the
retained home control plane.

The target `gateway` entry above means Gateway mesh on both substrates and the registered DNS
mutation capability on home only; EKS Gateway DNS is disabled. Each emitter has one encrypted,
identity-bound local journal. Heartbeat persistence uses that local
retained journal, not a shared remote object-store transaction. On EKS, the pre-created static
`Retain` CSI EBS PV uses `ReadWriteOncePod`. Home `hostPath`/local-PV storage is node-pinned and
cannot claim that CSI-only access mode; stable identity, exact mount, an exclusive OS filesystem
lock, a Kubernetes Lease/incarnation witness, and the persisted incarnation jointly admit the one
actor that owns stage→fsync→publish→commit→fsync. The Lease is not the sole fence. A missing
journal after prior admission fails closed.

The retained Lifecycle Authority is one cross-substrate control-plane dependency rather than a
second per-substrate writer. Its bounded CAS aggregate in the retained home/control-plane
`prodbox-state` store contains the authority epoch, fences, operation journal, provider revision,
credential generation, and durable per-target outbox. Large Pulumi checkpoints are immutable,
content-addressed encrypted blobs referenced by that aggregate. The AWS substrate reaches this
explicit authority service; it never substitutes its Gateway Runtime or Target Secret Agent.

Every per-substrate runtime role is physically isolated: distinct Deployment/StatefulSet, Service,
ServiceAccount, Vault policy, NetworkPolicy, Guaranteed-QoS resource envelope, bounded queue,
admission budget, and constant-time lifecycle probes. A gateway CPU throttle or restart therefore
cannot consume the Lifecycle Authority or Target Secret Agent's queue, credential session, or
deadline budget.

All cross-component prerequisites are operation-indexed `CapabilityRef` values. Observation,
admission, and execution use the same opaque reference, binding operation kind, service identity,
substrate/authority scope, endpoint, epoch/generation, and latency budget. A gateway GET, an absent
object, or a target-agent CAS cannot satisfy Lifecycle Authority submit/CAS readiness.

The in-cluster registry (`registry:2`) + MinIO + the Percona operator are therefore installed on
**both** substrates; the AWS
substrate is **not** a "no-registry" cluster. When AWS appears to be "missing" a shared platform
piece the home cluster has, the fix is to extend the shared inventory and the AWS installer,
never to render different image refs or re-pin versions per substrate.

Both substrates also stand up an in-cluster Vault on a durable PV from the shared
`[PlatformComponent]` inventory, **installed identically on both as the
sole, finalized secrets / key-management / encryption-as-a-service / PKI root**. Vault is **not** a
substrate — that word is reserved for the home-local and AWS substrates — it is a platform component
that **both** substrates run identically, exactly like the registry, MinIO, and the Percona operator.
Every post-unseal operational secret/credential/key/cert is a Vault object (KV v2, Transit, or
PKI), with no second operational store or plaintext fallback. The password-sealed Tier-1 recovery
bundle and memory-only operator prompt are the bounded bootstrap exceptions. A sealed (or unreachable/uninitialized) Vault **bricks** whichever substrate
is active, reducing the cluster to an opaque durable-data pile until it is unsealed. The same
shared-inventory coverage test that keeps the registry/MinIO/Percona in lockstep across both installers
extends to the Vault component, so neither installer may silently drop it.

Block storage is likewise identical in **discipline** across both substrates and different only in
**source**: every PV is a static, no-provisioner, `Retain`, `claimRef`-bound volume with
deterministic rebinding — a `hostPath` under `.data/` on home, a pre-created EBS volume lifted in via
the EBS CSI `volumeHandle` (AZ-pinned) on EKS. There is no dynamic provisioning on either substrate.
Production retains the EBS volumes exactly as it retains `.data/`; the test harness deletes only
test-scoped EBS at suite postflight (Sprints `7.28`, `4.39`, `4.40`). The volume source is one of the
genuinely substrate-specific LOWER-layer differences (alongside the ingress load-balancer and
Route 53 hosting), owned by
[../documents/engineering/storage_lifecycle_doctrine.md § 1](../documents/engineering/storage_lifecycle_doctrine.md).

The federation / downstream-cluster relationship between a root cluster and its child clusters — the
Vault transit-seal trust tree, parent custody of encrypted child recovery material plus revocation
attestations, and downstream-cluster inventory as secret data — is governed by
[../documents/engineering/cluster_federation_doctrine.md](../documents/engineering/cluster_federation_doctrine.md);
it is a cross-cluster trust relationship, not a substrate distinction, so it does not change the
substrate-equivalence invariant above (both substrates still stand up the identical service set).
See [../documents/engineering/vault_doctrine.md → §2 The fail-closed invariant](../documents/engineering/vault_doctrine.md#2-the-fail-closed-invariant)
and [§5 Vault deployment model](../documents/engineering/vault_doctrine.md#5-vault-deployment-model).

## Substrate Vocabulary and Orthogonal Axes

**Cluster type is explicit.** Every prodbox cluster declares its type — one of `kind`, `rke2`,
or `eks` — never inferred; the topology types make an ill-formed cluster shape unrepresentable per
[../documents/engineering/cluster_topology_doctrine.md](../documents/engineering/cluster_topology_doctrine.md).

**Three orthogonal Dhall axes.** "Substrate" stays the canonical, unoverloaded word for the
deployment substrate. The full model factors into three independent axes —
`clusterType {kind, rke2, eks}` × `hostSubstrate {apple-silicon, linux-cpu, linux-cuda,
windows-cpu, windows-cuda}` × `deploymentSubstrate {home-local, aws}` — where cluster type is
*what kind of Kubernetes* stands up, host substrate is *what the operator's machine is* (per
[../documents/engineering/host_platform_doctrine.md](../documents/engineering/host_platform_doctrine.md)),
and deployment substrate is the home-local vs AWS axis this document inventories. Each is set
independently and none overloads the others.

## Substrate Inventory

### Home Local Substrate

| Field | Value |
|-------|-------|
| Provision | `prodbox cluster reconcile` followed by `prodbox charts reconcile <chart>` for the canonical chart set |
| Teardown | `prodbox cluster delete --yes` (local uninstall that preserves retained host roots and leaves per-run AWS stacks untouched); `prodbox cluster delete --cascade` also destroys per-run AWS stacks before uninstall |
| Target inventory | Local RKE2 cluster on the operator host; MetalLB L2/BGP; Envoy Gateway; cert-manager with real ZeroSSL; registry + MinIO + Vault + Percona; the supported application charts; a physically separate pre-Vault Bootstrap Broker; the retained Lifecycle Authority; a home Target Secret Agent with closed SES-SMTP/ACME-EAB custody; private Backup/TLS Adapters and Provider Worker; permit-created Credential Provisioner, External Material Ingress, and Admin Action Runner Jobs; and mesh/DNS-only Gateway Runtime replicas, each with its own encrypted identity-bound retained journal. The authority stores one bounded CAS aggregate/outbox plus immutable encrypted checkpoint blobs in retained home `prodbox-state`; the target agent alone mutates allowlisted home Vault KV. |
| Required Config | `route53.zone_id`, `domain.demo_fqdn`, non-secret `acme.*` coordinates (ZeroSSL `server`, account email, and the typed requirement for an EAB generation), `deployment.*`, and non-secret `ses.*` coordinates (sender_domain, receive_subdomain, capture_bucket — required for `keycloak-invite` validation). `config setup` remains Tier-0-only. ACME EAB material enters through its distinct schema-indexed external-material permit/ingress; it never reuses the AWS-admin session. Elevated/admin AWS power enters prodbox only through the interactive `SecretRef.Prompt`; under the harness the test-only `aws_admin_for_test_simulation.*` fixture in `test-secrets.dhall` (TestPlaintext, never imported by production config, never in Vault) simulates that prompt for the bounded identity plan and explicit admin actions. Missing any required coordinate or required material receipt fails fast; the home substrate does not fall back to AWS-substrate values. |
| Target capability prerequisites | Existing host/config/Kubernetes/AWS prerequisites plus exact operation-indexed `CapabilityRef` admission for Bootstrap Broker Vault recovery, retained Lifecycle Authority observe/CAS/submit, the home Target Secret Agent observe/CAS/read-back, and Gateway mesh/DNS. Each reference binds the service identity, authority/substrate scope, endpoint, epoch or generation, and one absolute latency budget; none may substitute for another. |
| Phase ownership (provision/teardown) | [phase-4-lifecycle-canonical-paths.md](phase-4-lifecycle-canonical-paths.md) |
| Suite parity | Required coverage: Sprints `1.61`–`6.4` provide prerequisite home evidence; Sprint `8.12` reruns `LCPC-2026-07-11`, consecutive home aggregates, exact identities/envelopes/load, fault isolation, canonical restoration, invite flow, and residue re-observation as the sole final owner. Earlier runs remain revision-scoped historical evidence. Current status/evidence live only in [README.md → Deployment Qualification](README.md#deployment-qualification). |
| Resource isolation | Bootstrap Broker, Lifecycle Authority, Target Secret Agent, and Gateway Runtime have distinct workloads, Services, ServiceAccounts, Vault policies, NetworkPolicies, resource envelopes, queues, and readiness identities. Gateway CPU pressure cannot consume retained-authority admission or target delivery. |
| Cleanup | The suite registers cleanup before mutation and executes the always-run DAG: stop new work/transports; resolve nonterminal authority operations; restore home control plane and charts; destroy per-run AWS/reap test EBS; remove operational IAM only after credential-dependent cleanup; re-observe every lifecycle class and aggregate all failures. |
| Notes | The home cluster hosts the retained Lifecycle Authority and is also a canonical-suite substrate. Gateway charts no longer carry bootstrap, generic object-store, Pulumi, lifecycle, SES, or target-secret proxy authority. |

**Host provider dimension.** The home local substrate is host-native on Linux, but the same
cluster and the identical platform component set also stand up inside a Lima VM on macOS and a
WSL2 distro on Windows — the `prodbox` binary classifies the host OS and descends into a Linux
execution frame per
[../documents/engineering/host_platform_doctrine.md](../documents/engineering/host_platform_doctrine.md).
The host provider is an axis orthogonal to the substrate: it changes only *how* a Linux frame is
reached, never *which* services are stood up, so substrate equivalence is preserved.

### AWS Substrate

| Field | Value |
|-------|-------|
| Provision | `prodbox aws stack eks reconcile` (EKS test cluster), `prodbox aws stack aws-subzone reconcile` (per-substrate Route 53 subzone), and `prodbox aws stack test reconcile` (three Ubuntu 24.04 EC2 instances for HA-RKE2) |
| Teardown | `prodbox aws stack eks destroy --yes`, `prodbox aws stack aws-subzone destroy --yes`, and `prodbox aws stack test destroy --yes` |
| Historical inventory | Three per-run Pulumi stacks: registry `aws-eks` / Pulumi stack id `aws-eks-test` (dedicated VPC, EKS cluster/node group/IAM/security group), `aws-eks-subzone`, and `aws-test`. Sprint `7.30` historically accessed opaque Model-B state through the gateway daemon object-store API; that transport is the pre-cutover baseline scheduled for deletion in Sprint `4.50`, not the target architecture. Sprint `7.29`'s fresh-EKS-VPC guarantee remains valid. |
| Target inventory | The same substrate-local service set as home: cert-manager + real ZeroSSL, Envoy Gateway, registry + MinIO + Vault + Percona, canonical application charts, a physically separate Bootstrap Broker, an AWS Target Secret Agent, and Gateway Runtime replicas whose mesh remains active but whose DNS mutation capability is disabled, with encrypted identity-bound journals on pre-created static `Retain` EBS PVs. Cross-substrate Pulumi/lifecycle operations use the explicit retained home Lifecycle Authority and its aggregate/immutable blobs; the AWS target agent owns only allowlisted AWS-substrate Vault KV CAS/read-back. Gateway and target-agent endpoints cannot be used as retained authority. The lower-layer differences remain MetalLB versus AWS Load Balancer Controller/NLB, parent zone versus delegated subzone, and hostPath versus pre-created EBS. |
| Required Config | `aws_substrate.subzone_name` (the AWS-substrate public FQDN, e.g. `aws.test.resolvefintech.com`), optional `aws_substrate.hosted_zone_id` when an operator wants to pin the already-provisioned subzone ID in config, `ses.*` (sender_domain, receive_subdomain, capture_bucket — shared cross-substrate; same values as home substrate), AWS operator credentials, plus the same `acme.*` settings the home substrate uses. During harness-driven AWS runs, the suite reads the live `aws-eks-subzone` Pulumi output after provisioning and passes the hosted-zone ID to child commands. Missing AWS-substrate values fail fast; the AWS substrate does not fall back to `route53.zone_id` or `domain.demo_fqdn` from the home substrate. |
| Target capability prerequisites | Existing AWS/config/stack prerequisites plus exact operation-indexed `CapabilityRef` admission for the EKS Bootstrap Broker, retained Lifecycle Authority observe/CAS/submit, the AWS Target Secret Agent observe/CAS/read-back, and EKS Gateway mesh. The AWS A-record mutation reference belongs to retained Lifecycle Authority's registered provider intent; no EKS Gateway DNS reference exists. The retained authority reference is control-plane-scoped; the target-agent reference is AWS-substrate-scoped. No missing AWS coordinate falls back to home, and no target coordinate is promoted to authority. |
| Phase ownership (provision/teardown) | [phase-7-aws-substrate-foundations.md](phase-7-aws-substrate-foundations.md) |
| Suite parity | Required coverage: Sprint `7.33` provides prerequisite AWS isolation evidence; Sprint `8.12` is the sole final owner of AWS `LCPC-2026-07-11`, consecutive AWS aggregates, exact retained-authority/target routing, EKS replacement, fault isolation, invite specialization, and full cleanup. Historical runs remain revision-scoped evidence. Current status/evidence live only in [README.md → Deployment Qualification](README.md#deployment-qualification). |
| Resource isolation | EKS renders separate broker, target-agent, and gateway workloads/identities/envelopes; retained Lifecycle Authority transport is independent. The fault campaign must show gateway throttling/restart cannot consume authority or target-agent admission and EKS replacement refreshes every role-specific client. |
| Cleanup | The shared always-run DAG drains transient transports, resolves retained operations, restores the home authority/control plane, destroys all per-run AWS stacks and test EBS, removes each role-specific IAM/key resource only after its dependent cleanup, commits the corresponding Vault tombstone, and authoritatively re-observes absence/retention for every class on success, failure, and cancellation. |
| Notes | The AWS substrate is exclusively a test substrate. There is no production EKS cluster that `prodbox` manages. The literal stack names (`aws-eks-test`, `aws-test`) reflect that; the retained Lifecycle Authority remains a cross-substrate control-plane dependency, not an EKS gateway service. |

## Deployment Qualification Requirements

This file records required coverage only. It intentionally states no qualification status; the
sole status/evidence ledger is
[README.md → Deployment Qualification](README.md#deployment-qualification), as required by
[Standard P](development_plan_standards.md#p-deployment-qualification-and-counterexample-closure).

| Substrate | Required current-revision evidence | Evidence/status owner |
|-----------|------------------------------------|-----------------------|
| Home local | Consecutive full aggregates under authored resource envelopes; `LCPC-2026-07-11` old/new results; gateway saturation/restart while retained work continues; authority restart at every CAS/journal boundary; Target Secret Agent outage/resume; client cancellation and applied-but-response-lost recovery; always-run cleanup with canonical restoration and residue re-observation | [README.md → Deployment Qualification](README.md#deployment-qualification) |
| AWS | The home matrix plus AWS `LCPC-2026-07-11`, exact retained-authority/AWS-target `CapabilityRef` binding, EKS replacement/client refresh, target-agent isolation, per-run stack/EBS/DNS/IAM cleanup, and the full durable invite workflow against AWS-owned DNS/TLS/ingress | [README.md → Deployment Qualification](README.md#deployment-qualification) |

A point readiness response, a green historical aggregate, or one substrate's evidence cannot
qualify the other substrate. Qualification is invalidated by changes to topology, capability
wiring, deadlines, queues, resource envelopes, persistence, lifecycle orchestration, substrate
routing, or cleanup.

## Target Durable State and Cleanup Topology

The retained Lifecycle Authority owns one bounded, versioned, CAS-updated aggregate containing the
authority epoch/time floor, active fences, operation journal, provider revision, committed
credential generation, and per-target delivery outbox. Pulumi checkpoint bytes are immutable,
content-addressed, Vault-Transit-encrypted blobs; the aggregate references their digests rather
than rewriting a checkpoint for each workflow transition. Primary envelope/blob bytes live in
retained home MinIO; every transition prepares and receipt-commits exact envelope bytes and
verified blob ciphertext at an independently credentialed S3 backup coordinate in the long-lived
retained bucket before external effects. The two coordinates cannot alias one failure domain.
Transport ambiguity is resolved by operation ID, aggregate observation, and external postcondition
observation.

Each substrate's Target Secret Agent owns only its allowlisted Vault KV generation/opaque keyed-
commitment/version fold. Delivery is at least once: an identical generation/commitment is idempotent, regression or
same-generation commitment drift refuses, and the authority completes an outbox intent only after
mandatory target read-back. Each Gateway Runtime owns only its encrypted local emitter journal;
no authority aggregate, Pulumi checkpoint, SES lease, or target secret is gateway state.

Before any destructive mutation, the suite durably commits the pure cleanup DAG and its per-node
operation IDs. A fenced cleanup-run owner may restart and resume it; completion is not dependent on
the original runner process surviving. The exact canonical order is owned by Integration Fixture
Doctrine. This substrate inventory adds the AWS dependency edges: typed EKS drain runs while the
controllers are live; Certificate/Challenge, registered A/TXT records, and the hosted-zone canary
are removed/read back before provider destroy; per-run stacks, controller-created load-balancer
resources, and test EBS are then destroyed/reaped; operational IAM waits for every cleanup that
uses its generation. AWS drain skip/failure remains a recorded failure, while a `RequiresAttempt`
edge still runs provider cleanup. The original suite failure and every cleanup failure remain in
the final Standard-P evidence.

## Resource Lifecycle Classes

Every AWS resource any `prodbox` flow creates falls into exactly one of three lifecycle classes.
This section is the authoritative classification — when adding a new AWS resource to any
`prodbox` code path, it must land in one of these three classes (and in the matching inventory
table below). Pulumi state lifetime must also match resource lifetime per class; see
[../documents/engineering/lifecycle_reconciliation_doctrine.md → §2 State-Lifetime Rule](../documents/engineering/lifecycle_reconciliation_doctrine.md).

> **Scope note — the Vault durable PV is not an AWS resource.** The in-cluster Vault's durable
> volume is **local retained state** under `.data/vault/vault/0`, governed by the storage lifecycle
> doctrine, not by the AWS resource lifecycle classes — so it does **not** appear in the per-run,
> long-lived, or operational AWS tables below. It is preserved across cluster teardown exactly
> like the MinIO PV, so a wipe-and-rebuild keeps Vault's sealed
> ciphertext stores intact. See
> [../documents/engineering/vault_doctrine.md → §5 Vault deployment model](../documents/engineering/vault_doctrine.md#5-vault-deployment-model).

The per-run vs long-lived partition is mirrored in code by `Prodbox.Aws.perRunStackNames`
and `Prodbox.Aws.longLivedResourceNames` (Sprint `7.7`), which the
`Prodbox.Aws.partitionResidueByLifecycle` predicate and the `PulumiResiduePolicy`
`BypassPerRunResidueOnly` arm consume. The `prodbox aws teardown` flag surface
(`--destroy-pulumi-residue`, `--allow-pulumi-residue`) and the harness-internal
`BypassPerRunResidueOnly` mode both depend on the partition being authoritative here.

The registry SSoT is `Prodbox.Lifecycle.ResourceClass.resourceLifecycleClasses` (Sprint
`4.20`); `perRunStackNames` / `longLivedResourceNames` are derived from it. The table below is
**generated** from that registry by `prodbox dev docs generate` (Sprint `4.22`) — do not hand-edit
between the markers; `prodbox dev docs check` fails the build if it drifts from the code, so a new
resource cannot be added to the registry without this inventory updating in lockstep:

<!-- prodbox:resource-lifecycle-classes:start -->
| Resource | Lifecycle class |
|----------|-----------------|
| `aws-eks` | PerRun |
| `aws-eks-subzone` | PerRun |
| `aws-test` | PerRun |
| `pulsar-topics-per-run` | PerRun |
| `aws-ses` | LongLived |
| `aws-ebs-volumes` | LongLived |
| `public-edge-tls` | LongLived |
| `pulsar-topics-long-lived` | LongLived |
| `operational-aws-ses-lease-role` | Operational |
| `operational-iam-user` | Operational |
| `operational-aws-config` | Operational |
<!-- prodbox:resource-lifecycle-classes:end -->

The target encrypted gateway emitter journals are retained managed resources. Their implementing
sprint must add the new resource identity/class to the typed registry and regenerate this section;
this design change deliberately does not hand-edit the generated table before that code exists.

Each Pulumi-managed substrate stack is described by one `StackDescriptor` SSoT record
(`Prodbox.Infra.StackDescriptor`, Sprint `4.27`): its registry name, Pulumi stack id, project
subdir under `pulumi/`, CLI verb stem, and lifecycle class. The per-run name list
(`Prodbox.Aws.perRunStackNames`), the CLI verbs, and the project dirs are **derived** from it
rather than hand-maintained, removing the drift the documentation-harmony audit flagged between
the registry names, the CLI verbs, and the project directories. The registry-name↔CLI-command
table below is **generated** from `stackDescriptors` by `prodbox dev docs generate` — do not hand-edit
between the markers; `prodbox dev docs check` fails the build if it drifts. This is the typed source
Sprint `0.10` consumes for the registry-name↔CLI-verb list and Sprint `5.6` consumes for
registry-generated golden coverage:

<!-- prodbox:stack-command-surface:start -->
| Registry name | Pulumi stack id | Project subdir | Resources command | Destroy command | Lifecycle class |
|---------------|-----------------|----------------|-------------------|-----------------|-----------------|
| `aws-eks` | `aws-eks-test` | `pulumi/aws-eks/` | `prodbox aws stack eks reconcile` | `prodbox aws stack eks destroy --yes` | PerRun |
| `aws-eks-subzone` | `aws-eks-subzone` | `pulumi/aws-eks-subzone/` | `prodbox aws stack aws-subzone reconcile` | `prodbox aws stack aws-subzone destroy --yes` | PerRun |
| `aws-test` | `aws-test` | `pulumi/aws-test/` | `prodbox aws stack test reconcile` | `prodbox aws stack test destroy --yes` | PerRun |
| `aws-ses` | `aws-ses` | `pulumi/aws-ses/` | `prodbox aws stack aws-ses reconcile` | `prodbox aws stack aws-ses destroy --yes` | LongLived |
<!-- prodbox:stack-command-surface:end -->

### Per-run stacks (auto-managed by the harness)

| Stack | Provisioned by | Destroyed by | Pulumi state backend |
|-------|----------------|--------------|----------------------|
| `aws-eks` | `prodbox aws stack eks reconcile` (and implicitly by `prodbox test all` / `prodbox test integration … --substrate aws` when needed) | `prodbox aws stack eks destroy --yes`; auto-destroyed by the test-harness postflight on success, failure, **and** Ctrl-C (Sprint `7.6`); also destroyed by `prodbox cluster delete --cascade` (Sprint `4.11`) | Target: immutable encrypted checkpoint blob referenced by the retained Authority aggregate, read back from primary MinIO and independent S3 backup before promotion. Sprint `7.30` gateway transport is pre-cutover. |
| `aws-eks-subzone` | `prodbox aws stack aws-subzone reconcile` | `prodbox aws stack aws-subzone destroy --yes`; auto-destroyed by the test-harness postflight (Sprint `7.6`); also destroyed by `prodbox cluster delete --cascade` (Sprint `4.11`). Target cleanup first deletes and reads back every exact registered A/TXT/canary owner. A bounded non-NS/SOA sweep is last-resort residue discovery/attempt only; it cannot turn a failed or unobservable exact-owner node into success. | Target: immutable encrypted checkpoint blob referenced by the retained Lifecycle Authority aggregate; no gateway or target-agent backend access. |
| `aws-test` (HA-RKE2 EC2) | `prodbox aws stack test reconcile` | `prodbox aws stack test destroy --yes`; auto-destroyed by the test-harness postflight (Sprint `7.6`); also destroyed by `prodbox cluster delete --cascade` (Sprint `4.11`) | Target: immutable encrypted checkpoint blob referenced by the retained Lifecycle Authority aggregate; no gateway or target-agent backend access. |

Per-run stacks exist only for the lifetime of a suite run that needs them. The harness owns
the full create/destroy lifecycle; operators do not normally invoke the destroy commands by
hand because the harness already does so on every exit path. Pulumi checkpoint blobs and the
authority aggregate live in MinIO on the retained home/control-plane `.data` volume so an
interrupted run can still be observed and destroyed after cluster rebuild. The retained Lifecycle
Authority, not a Gateway Runtime or loss of the active cluster, owns operation resumption and
checkpoint references. The harness ends the AWS resource lifetime and prunes the aggregate
reference only after authoritative destruction and re-observation; immutable-blob garbage
collection is a separately fenced cleanup.

### Long-lived cross-substrate shared infrastructure (retained by design)

| Resource | Provisioned by | Destroyed by | Pulumi state backend |
|----------|----------------|--------------|----------------------|
| `aws-ses` provider stack (sending identity, DKIM, MX, receive rule set, S3 capture bucket) | `prodbox aws stack aws-ses reconcile`; invite-capable validation submits the same idempotent durable operation to the retained Lifecycle Authority | `prodbox aws stack aws-ses destroy --yes` — **only on explicit invocation**; never auto-destroyed by the test-harness postflight, never destroyed by `prodbox cluster delete` (any flag); destroyed transitively by `prodbox nuke` | Immutable encrypted checkpoint referenced by the Authority aggregate: primary in home MinIO plus mandatory exact S3 backup copy/read-back. The Pulumi program and Provider Worker never own an SMTP IAM principal, policy, access key, or key material. `LongLivedCheckpointAuthority` is an identity/namespace, never a gateway URL. |
| SES SMTP IAM identity, least-privilege send policy, finite access-key family, retained-home `SesSmtpSource` custody, and per-target `secret/keycloak/smtp` generations | A receipt-committed `OperatorMaterialPermit` selects the deterministic `LongLived` identity. The Credential Provisioner alone creates, rotates, or remints it and performs repair-time key deletion. In bounded memory it constructs the region-bound SMTP payload—username from access-key ID and password derived from the one-time secret plus region—discards the raw AWS secret, and directly hands only the closed `SesSmtpSource` payload to the retained-home Target Secret Agent for Transit sealing; selected Agents receive only attestation-bound rewraps and seal/read back their generation. | The `DestroyAwsSes` DAG first proves every consumer quiescent and obtains the Provider Worker's authoritative provider-stack absence receipt. The Admin Action Runner then deletes/read-backs the exact registered key family, policy, and principal. While Agents are still live it finally tombstones/read-backs target generations and retained-home custody; the always-run DAG aggregates every failure. Ordinary suite postflight, `aws teardown`, and `cluster delete` retain all of it. | **Not Pulumi state.** The registered identity/key-family descriptor, credential-generation state, schema-bound custody ciphertext/receipt, and target-delivery receipts live in the durable Authority aggregate/outbox and exact Agent lanes; no checkpoint or stack output contains access-key material. |
| Long-lived `pulumi_state_backend` S3 bucket (Sprint `4.10`; target adds registered `AuthorityBackupStore`) | `ensureLongLivedPulumiStateBucket` when retained TLS, authority backup, or legacy first-touch state requires it. Sprint `4.48` adds a separately credentialed opaque backup coordinate/descriptor. | Exported-manifest `prodbox nuke` only: delete/read-back TLS and any legacy prefix objects/versions without deleting the bucket; the final Authority-backup node proves every registered prefix absent, then deletes the shared bucket last. Never destroyed by `aws teardown` or `cluster delete`. | Independent encrypted backup copies of authority envelopes/blobs plus retained public-edge TLS and optional legacy import. It is never the primary current checkpoint backend and no Gateway has access. |
| Authority-backup IAM identity/key/policy plus `secret/aws/authority-backup-store` generation | Genesis/repair-mode Credential Provisioner from the ephemeral admin prompt; exact get/put/list/delete scope only for the registered opaque backup coordinate | Exported-manifest `prodbox nuke`, in the final backup/shared-bucket node after every other prefix is absent; never ordinary `aws teardown`/suite postflight | Registered `LongLived` credential generation retained with the backup store. Only the separately deployed home Authority Backup Adapter may read it; core Authority, provider, Gateway, Target Agent, and cert-manager cannot. |
| Home Gateway-DNS IAM identity/key/policy plus `secret/aws/gateway-dns` generation | Operator-material-mode Credential Provisioner after genesis; exact home public A-record scope | `prodbox nuke` or explicit home Gateway decommission after record cleanup/read-back; never ordinary suite postflight/`aws teardown` | Registered `LongLived` generation retained with the restored home Gateway so background repair remains possible. |
| Home cert-manager-DNS01 IAM identity/key/policy plus `secret/aws/cert-manager/home/dns01` generation | Operator-material-mode Credential Provisioner after genesis; exact home DNS01 scope | `prodbox nuke` or explicit home cert-manager decommission after Certificate/Challenge/TXT cleanup; never ordinary suite postflight/`aws teardown` | Registered `LongLived` generation retained with live home cert-manager so renewal remains possible. |
| TLS-retention-store IAM identity/key/policy plus `secret/aws/tls-retention-store` generation | Operator-material-mode Credential Provisioner after genesis; exact `public-edge-tls/<substrate>/<canonical-scope-key>` prefix only | Explicit TLS-consumer decommission or `prodbox nuke`, after every retained TLS object version is deleted/read back and consumers are stopped, without deleting the shared bucket; never ordinary postflight | Registered `LongLived` generation consumed only by the home TLS Retention Adapter. Ciphertext DEKs remain wrapped by retained-home Vault Transit, never an ephemeral AWS Vault key. |
| Operator-owned Route 53 parent zone for the configured public FQDN | Operator-managed in Route 53 (no `prodbox aws stack` flow) | Operator action against Route 53 — outside the harness surface | n/a |
| Public-edge TLS certificate material | Selected Target Agent observes the exact issued Secret, encrypts locally using a DEK issued/wrapped by retained-home Transit, and sends ciphertext through Authority to the TLS Retention Adapter at `public-edge-tls/<substrate>/<canonical-scope-key>` | Explicit TLS-consumer decommission or `prodbox nuke`; ordinary postflight retains home material and restores AWS material before issuance after rebuild | Long-lived S3 ciphertext + home-Transit-wrapped DEK keyed by the exact canonical SAN set; selected Agent alone materializes/read-backs the Kubernetes Secret. |

Retained by design — not orphaned. SES domain identity + DKIM verification requires 5–30 min
of DNS propagation per provision; only one receive rule set may be active per AWS account; S3
bucket names have a ~24-hour reuse cooldown; and re-ordering the public-edge ZeroSSL certificate
on every rebuild would needlessly consume ZeroSSL issuance quota — the TLS analogue of the SES
cooldown — so the public-edge certificate is issued once and restored from the long-lived S3
store on every rebuild rather than re-ordered. Per-run re-provision is impractical at suite
cadence. The harness explicitly carves these resources out of postflight auto-destroy so
operators can run the suite at a sane cadence without rebuilding shared infrastructure each
time. Retention controls teardown only: an invite-capable suite still ensures the desired-present
provider stack and registered SMTP identity, then retains both. The target `aws-ses` checkpoint is
an immutable Model-B blob referenced
by the retained Lifecycle Authority aggregate in home/control-plane `prodbox-state` and Vault
keyspace. Its authority `CapabilityRef` is distinct from the selected substrate's Target Secret
Agent `CapabilityRef`, which performs allowlisted SMTP KV CAS/read-back for the
registered credential generation. A closed `SesSmtpSource` home-Agent custody/rewrap capability
lets a fresh AWS Agent/Vault restore that same generation without a new prompt or key rotation;
the Authority sees only ciphertext and receipts, and no generic secret export exists. The configured
long-lived S3 store retains public-edge TLS material and may supply a legacy SES checkpoint on
first touch; it is not the primary current stack backend. If the Model-B checkpoint is missing or
corrupt while fixed-name AWS resources are positively observed, the implemented desired-present
planner chooses explicit import/repair rather than create; positively absent resources choose an
explicit create action. The lease, target-intent, SMTP-key-repair, and fenced-checkpoint modules
implement the Model-B protocol, and unobservable AWS or checkpoint state never lowers to
absence/missing. Sprint `4.47` remains historical evidence for those decision rules; Sprints
`4.48`–`4.50` move the generic protocol and registered target descriptors into the durable authority
aggregate/outbox. Sprint `8.11` freezes and migrates the legacy Pulumi-owned SMTP identity to the
sole Credential-Provisioner writer and narrows the SES mutation fence so propagation and target
delivery do not hold one long synchronous lease.

When an operator wants the long-lived resources gone (e.g., decommissioning the project or
account), the supported path is the explicit destroy command in the table above, or the
operator-only `prodbox nuke` for total teardown. Target `nuke` exports and fsyncs its signed
decommission manifest before irreversible work; rerun resumes from the same receipt plus a fresh
admin prompt, and deletes the Authority backup objects/identity/store last. There is no "managed-by-someone-else"
category — the harness still owns the create/destroy lifecycle; it simply does not invoke
destroy on its own for this class.

### Controller-created and registered DNS AWS resources

| Resource | Created by | Tag signature | Destroyed by |
|----------|------------|---------------|--------------|
| EBS volumes for PVCs (superseded → pre-created `Retain`) | **Historically** the EBS CSI driver dynamically responded to `PersistentVolumeClaim` resources. Sprint `7.28` replaced this with **pre-created EBS volumes lifted in as static `Retain` PVs** — a registered managed resource (typed `discover`/`destroy`, Sprint `4.39`), no longer controller-created. | `prodbox.io/managed-by: prodbox` + a retain-vs-test-scoped marker (test volumes also `kubernetes.io/cluster/<cluster-name>: owned`) | Retained on teardown (`Retain`, not Pulumi-owned); test-scoped volumes deleted by the suite postflight reaper (Sprint `4.40`) — **not** the drain. The dynamic path is in [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md) Completed. |
| ALBs / NLBs / target groups / listeners / security groups | AWS Load Balancer Controller responding to a registered `Service`/`Ingress` owner | Register account/region/cluster, deterministic manifest/name and tags; create the owner inert, CAS-enrich its Kubernetes-assigned UID, then enable controller mutation and CAS-enrich exact ARNs | Delete the Kubernetes owner while the controller is live, then use the registered bounded AWS-family discover/destroy/read-back program for any survivor. The tag query is a selector for that program and postflight evidence, not a diagnostic-only substitute. |
| Route 53 TXT records (`_acme-challenge.*`) | cert-manager DNS01 solver using its substrate-local DNS01 identity | Exact account/zone/name/type coordinates registered before issuance and confirmed from Challenge observations | Sprint `5.18`'s always-run cleanup deletes Certificate/Challenge resources while cert-manager is live, then observes every registered TXT coordinate and fails on residue or unobservability |
| Home Route 53 public A record | Elected Gateway DNS capability using the dedicated Gateway-DNS identity | Registered account/zone/name/type plus Gateway ownership epoch | Gateway desired-absent operation plus authoritative read-back through the same capability; no alternate writer fallback |
| AWS-substrate Route 53 public A record | Lifecycle Authority AWS-edge provider intent using its narrow provider session | Registered account/zone/name/type plus authority operation/epoch | Durable desired-absent provider operation plus authoritative read-back; no direct host or EKS-Gateway substitution |
| Hosted-zone capability canary | Visible suite preparation through a committed Lifecycle Authority intent | Register account/region/caller-reference/name plus operation/epoch before create; recover response loss by caller reference, then CAS-enrich the AWS-assigned zone ID | Sprint `5.18` always-run exact delete/read-back on success, failure, cancellation, or response loss; never hidden as a read-only prerequisite |

These resources are not Pulumi-tracked. Controller-created resources require drain plus exact
postcondition observation; registered DNS records require their single typed owner plus read-back.
The tag sweep remains an independent backstop, never the sole ownership record or a substitute for
an unobservable exact coordinate. The pre-cutover direct `aws route53` bootstrap call sites are
Pending Removal;
see
[../documents/engineering/lifecycle_reconciliation_doctrine.md](../documents/engineering/lifecycle_reconciliation_doctrine.md).

### Fixed-name IAM orphan residue (harness preflight residual class)

| Resource | Origin | Why it orphans | Cleanup owner |
|----------|--------|----------------|---------------|
| `aws-eks-test-aws-lb-controller` policy/role and `aws-eks-test-ebs-csi-driver` role (fixed-name) | The `aws-eks` Pulumi program (per-run) | A `pulumi up` partially succeeds (IAM created early), then its state is lost — the create-then-crash window, or a `.data/` wipe / cluster crash before the per-run `pulumi destroy` | Harness preflight, scoped to these exact names and only when the authoritative `aws-eks-test` Pulumi checkpoint is absent |
| auto-named `clusterRole-*` / `nodeRole-*` (pre-cutover residue) | The current `aws-eks` Pulumi program (per-run) | Provider-assigned names make exact recovery impossible after checkpoint loss | Sprint `7.33` replaces them with deterministic run/cluster-scoped names registered before create and exact discover/destroy/read-back. A target deployment cannot retain an operator-only leak class. |
| Registered Operational Lifecycle-provider or AWS cert-manager-DNS01 IAM identity/key/role | `prodbox aws setup` / the test-harness IAM bootstrap | An interrupted run leaves one role; cluster delete does not own operational identity | `prodbox aws teardown` or the harness postflight through the typed cleanup DAG; never ad-hoc IAM mutation. LongLived backup/TLS/home-DNS/SES-SMTP identities and custody receipts are not orphan residue and are excluded. |

The AWS Resource Groups Tagging API does not return IAM resources, so the postflight tag sweep
cannot see this class (see
[lifecycle_reconciliation_doctrine.md § 6a](../documents/engineering/lifecycle_reconciliation_doctrine.md)).
The current pre-cutover automation is intentionally narrow: `runAwsIamHarnessSetup` checks the
authoritative per-run `aws-eks-test` Pulumi checkpoint first, then deletes only the two
fixed-name IRSA roles and the fixed-name AWS Load Balancer Controller policy. If the policy is
attached to anything outside that exact harness-owned role set, the preflight fails loud instead
of detaching it. Broad IAM name scanning remains forbidden. The target removes provider-assigned
IAM names, registers every deterministic name before mutation, and therefore never depends on a
broad scan or operator investigation for resources it can create.

### Operational resources (registered, ephemeral per run)

| Resource | Created by | Discover | Destroyed by |
|----------|------------|----------|--------------|
| Fixed `prodbox-ses-lease-session` IAM role (+ exact inline policy) | Operator-material-mode Credential Provisioner through `prodbox aws setup` / cluster post-genesis setup / the test-harness permit path when the public SES scope is configured | typed `iam get-role` + `iam get-role-policy` observation in `Prodbox.Infra.AwsSesLeaseRole` | `prodbox aws teardown` (`reconcileAbsent`, before the trusted Lifecycle-provider identity, followed by authoritative absence re-observation) |
| Lifecycle-provider IAM identity/key/policy plus `secret/aws/lifecycle-provider` generation | Durable setup operation using the ephemeral admin prompt, then Target-Agent sealing/CAS delivery | exact IAM principal/key/policy plus Vault generation/opaque Agent-HMAC commitment/read-back | dependency-ordered provider cleanup, IAM/key deletion, then Vault tombstone |
| AWS cert-manager-DNS01 IAM identity/key/policy plus `secret/aws/cert-manager/aws/dns01` generation | AWS-run setup operation | exact IAM principal/key/policy plus Vault generation/opaque Agent-HMAC commitment/read-back | after EKS Certificate/Challenge/TXT and cluster cleanup, delete IAM/key then commit Vault tombstone |

Access-key creation is journaled before AWS mutation. If the one-time secret response is lost
before Target-Agent sealing, the uncommitted key ID is discovered, deleted, and observed stably
absent before remint; a blind second create is never a recovery action.

The pre-cutover implementation has one operational `prodbox` IAM user and
`secret/gateway/gateway/aws` generation. Sprint `4.50` removes that resource after every consumer is
re-observed on the split generations; this is an identity split, not merely a coordinate rename.

These rows describe the **target** `Operational`-class registry. LongLived Authority-backup,
TLS-retention, home Gateway-DNS, home-DNS01, and SES-SMTP rows above are deliberately excluded. The
current generated registry still exposes shared resources. Sprint `4.50` owns the Operational
Lifecycle-provider plus LongLived backup/TLS/home-DNS/SES-SMTP descriptors, provisioning protocol,
and backup genesis; Sprint `8.11` alone owns the live freeze-and-migrate cutover from the legacy
Pulumi-owned SMTP identity to that registered resource. Sprint `7.33` owns only the AWS Target-Agent projection and
run-scoped AWS cert-manager-DNS01 identity. Earlier Sprints `4.20`/`4.47`/`7.8` are historical
foundations, not claims that the split resources are already registered. The target gives each a data-only descriptor whose typed
observe and destroy/read-back programs let `aws teardown`'s `reconcileAbsent` interpreter reconcile
it like any other resource.

### Lifecycle ownership rule

No new AWS or cluster resource type may be added by any `prodbox` code path without a
corresponding **managed-resource registry** descriptor (typed observe and destroy/read-back
programs, with a
`LifecycleClass` of `PerRun` / `LongLived` / `Operational`). The registry
(`Prodbox.Lifecycle.ResourceRegistry`, Phase `4` Sprint `4.20`) is the
machine-enforced single source of truth: `Prodbox.Aws.perRunStackNames` /
`longLivedResourceNames` are **derived from** it, and `prodbox dev check` (Sprint `4.22`)
fails the build if this Resource Lifecycle Classes section drifts from the registry or if
any `aws`/`pulumi` create call site has no registered counterpart. The doctrine SSoT is
[../documents/engineering/lifecycle_reconciliation_doctrine.md § 3.1](../documents/engineering/lifecycle_reconciliation_doctrine.md).
This Resource Lifecycle Classes table is a registry-sourced generated section.

## Cross-Substrate Shared Resources

This table is the **authoritative inventory** of every AWS resource any `prodbox` flow may
create or destroy under the long-lived shared-infrastructure class above. No `prodbox` code
path may add a new AWS resource type without first appearing in this table (or in the
per-run-stacks table above for the auto-managed class). Both substrates depend on the
resources listed here; provisioning and teardown stay per-substrate for the per-run stacks
and one-time/on-demand for the resources below.

| Resource | Owner | Phase ownership | Provisioning surface | Used by |
|----------|-------|-----------------|----------------------|---------|
| Route 53 hosted zone for the configured public FQDN | Operator AWS account | [phase-7-aws-substrate-foundations.md](phase-7-aws-substrate-foundations.md) | Operator-managed in Route 53 (no `prodbox aws stack` flow) | Both substrates (home substrate for the live public record; AWS substrate when its parity sprint adds public-edge proofs) |
| AWS SES sending identity (domain) | Operator AWS account | Lifecycle/planning: [phase-4](phase-4-lifecycle-canonical-paths.md) / [phase-5](phase-5-canonical-test-suite.md); semantics: [phase-8](phase-8-email-invite-auth.md) | `prodbox aws stack aws-ses reconcile` / `prodbox aws stack aws-ses destroy --yes` remain the public surface. Target execution submits an idempotent operation through the retained Lifecycle Authority `CapabilityRef`; provider mutation commits a fenced provider revision before semantic polling. | Both substrates running `ValidationKeycloakInvite` |
| AWS SES receive subdomain + MX records + receive rule set + S3 capture bucket | Operator AWS account | Lifecycle/planning: [phase-4](phase-4-lifecycle-canonical-paths.md) / [phase-5](phase-5-canonical-test-suite.md); semantics: [phase-8](phase-8-email-invite-auth.md) | Same public reconcile/destroy surface; Sprint `8.10`'s exact classifier becomes a revision-bound authority stage. Propagation polling does not hold the narrow provider-mutation fence. | Both substrates running `ValidationKeycloakInvite` |
| Deterministic `LongLived` SES SMTP IAM identity, least-privilege send policy, finite access-key family, retained-home custody, and derived target generations | Credential Provisioner under a receipt-committed `OperatorMaterialPermit`; retained-home and selected Target Secret Agents own only schema-bound custody/rewrap/sealing and read-back | Lifecycle/protocol: [phase-4](phase-4-lifecycle-canonical-paths.md); ownership migration and SES semantics: Sprint `8.11` in [phase-8](phase-8-email-invite-auth.md) | The Lifecycle Authority journals the identity/key-family intent, credential generation, custody receipt, and durable per-target outbox. The Credential Provisioner is the sole create/rotate/remint and repair-time key-delete interpreter and derives the region-bound SMTP payload in-memory before discarding the raw IAM secret; Pulumi/Provider Worker cannot describe or mutate the identity. The retained-home Agent Transit-seals only the closed `SesSmtpSource` payload and rewraps only to an attested selected Agent, which seals/read-backs `secret/keycloak/smtp`; the Authority sees ciphertext/receipts only. Explicit `DestroyAwsSes` proves consumers quiescent, waits for the Provider Worker's provider-stack absence receipt, invokes the Admin Action Runner to delete/read-back the external IAM family, then tombstones target/custody Vault state while Agents are live, aggregating all failures. Ordinary postflight retains all of it. | Keycloak chart `smtpServer` block; native `ValidationKeycloakInvite` harness |

## Per-Validation Substrate Coverage Notes

The substrate `Suite parity` rows above track aggregate canonical-suite coverage per
substrate. Individual validations whose AWS-substrate coverage is on a separate axis from
their home-substrate suite-content closure are called out here, per the orthogonality rule
above and [development_plan_standards.md → N / O](development_plan_standards.md#n-phase-independence-no-backward-blocking).

| Validation | Home-substrate suite-content closure (owned surface) | AWS-substrate coverage (owned surface) |
|------------|------------------------------------------------------|----------------------------------------|
| Exact operation-indexed capability binding | **Pending Sprints `1.61`, `4.50`, `5.18`.** Home preparation must observe, admit, and execute through the same retained-authority or home-target `CapabilityRef`; wrong service, scope, operation, endpoint, epoch/generation, or freshness fails before mutation. | **Pending Sprint `7.33`.** AWS must bind the retained home authority separately from the AWS Target Secret Agent and reject EKS Gateway/target-agent substitution or fallback to home target coordinates. |
| Gateway journal and temporal resource isolation | **Sprint `2.32` code-local foundation Done; physical/live proof pending Sprints `3.26` and `5.19`.** The bounded actor, encrypted journal, journal-first admission, current Lease/incarnation fence, exact recovery, and typed substrate persistence coordinates are locally validated. The remaining home axis renders the physical workload/storage boundary and proves its CPU/queue/deadline SLOs under background Lifecycle Authority load, saturation, and restart. | **Pending Sprints `3.26` and `7.33`.** The shared code-local actor/journal foundation is Done; the AWS proof consumes retained EBS journals and independently resourced EKS broker/agent/gateway workloads, and proves EKS replacement refreshes clients without losing emitter identity or consuming authority admission. |
| Durable Lifecycle Authority crash/response-loss recovery | **Pending Sprints `4.48`, `4.50`, `5.19`.** Restart before/after every journal/CAS boundary, lost applied responses, cancellation, stale fences, and operation-ID replay converge under one authority epoch. | **Pending Sprint `7.33`.** The identical retained authority remains queryable while EKS gateway/target transports fail; no AWS target component becomes a second writer. |
| Target Secret Agent outage and resume | **Pending Sprints `4.49`, `5.19`.** Home outbox delivery is at least once, generation/opaque-commitment checked, read back, and resumed after agent/Vault outage without gateway participation. | **Pending Sprint `7.33`.** AWS target delivery uses only the AWS agent's allowlisted Vault coordinate and resumes after Pod/EKS replacement; home target evidence cannot satisfy it. |
| Always-run cleanup and residue re-observation | **Pending Sprints `5.18`, `6.4`.** Failure/cancellation at every mutation runs all dependency-ready cleanup, restores the canonical home control plane/charts, retains the primary failure, aggregates cleanup failures, and re-observes each resource class. | **Pending Sprint `7.33`.** The same DAG additionally proves per-run stacks/test EBS absent, retained authority quiescent, and operational IAM cleared only after credential-dependent cleanup. |
| Durable `keycloak-invite` workflow | **Pending Sprints `8.11`, `8.12`.** Revision-bound SES semantics, narrow provider mutation fence, committed credential generation, home target outbox/read-back, invite capture/link/OIDC, and cleanup must pass the full fault campaign. | **Pending Sprints `7.33`, `8.11`, `8.12`.** The same workflow targets the AWS agent and AWS-owned DNS/TLS/ingress with exact cross-substrate authority/target binding and complete cleanup. |
| Historical gateway runtime stability (bounded-memory/restart/OOM/high-water proof) | [phase-5-canonical-test-suite.md](phase-5-canonical-test-suite.md) Sprint `5.16` — Done for the prior topology: `gateway-pods` folds run-wide absorbing unhealthy evidence plus a separately restartable three-sample healthy window. It did not cover CPU throttling, queue wait, deadline misses, or separated authority services. | The historical typed validation targeted EKS. Its live soak remains evidence for that revision only and cannot satisfy Standard P for the target topology. |
| Historical `keycloak-invite` retained-SES preparation and semantic readiness | Sprint `5.17` remains Done over Sprint `4.47` for the gateway-backed bracket, and Sprint `8.10` remains Done for exact semantic classification. These are preserved inputs to, not qualification of, the durable workflow. | Historical cross-substrate authority/target types and semantic checks remain evidence for their revision. Sprints `7.33`/`8.11`/`8.12` replace the transport, workflow, and qualification boundary. |
| Sealed-Vault validation (the fail-closed sealed/unreachable/uninitialized-Vault proof) | [phase-5-canonical-test-suite.md](phase-5-canonical-test-suite.md) Sprint `5.8` — Done on its code-owned surface once the validation exists and passes on the home substrate (`prodbox dev check`, `test unit`, `test integration cli/env`); phase-5 closure depends on this axis only | [phase-7-aws-substrate-foundations.md](phase-7-aws-substrate-foundations.md) provisioning — the AWS-substrate run of the same validation is a parity-coverage row owned by phase 7. **`Live-proof: pending`** while it needs a deployed EKS cluster + an unsealed in-cluster Vault; non-blocking per Standard O, and never marks Sprint `5.8` or phase 5 ⏸️ Blocked |
| `resource-guardrails` (cpu/memory/storage request-limit and quota proof) | [phase-5-canonical-test-suite.md](phase-5-canonical-test-suite.md) Sprint `5.13` — Done on its code-owned surface: the named validation, command parser/registry, planner ordering, topology mapping, pod/quota/limit-range JSON oracle, and fake-`kubectl` integration proof are implemented and locally validated; the optional real over-limit pod stress proof is tracked as a non-blocking live-infra axis | AWS-substrate run of the same validation is a parity-coverage row once the AWS substrate is provisioned. **`Live-proof: pending`** while it needs a deployed EKS cluster with the resource-governed chart set; non-blocking per Standard O and never a backward block on Phase `5` |
| Historical `daemon-bootstrap` gateway-transport proof | [phase-5-canonical-test-suite.md](phase-5-canonical-test-suite.md) Sprint `5.14` remains Done for the old post-bootstrap daemon route/transport/redaction surface. Sprint `2.33` replaces pre-Vault gateway bootstrap with the minimal Bootstrap Broker. | Sprint `7.30` remains historical proof of gateway-mediated AWS/Pulumi object-store parity. Sprint `4.50` removes that transport; Sprint `7.33` proves the broker/authority/agent topology instead. |
| `eks-volume-rebind` (identical block-storage rebinding across a teardown/spinup cycle) | [phase-5-canonical-test-suite.md](phase-5-canonical-test-suite.md) Sprint `5.12` — Done on its code-owned surface: the named validation, command parser/registry, planner, topology mapping, PV JSON parser, and rebinding/sentinel oracle are implemented and unit-validated; the destructive home live proof is tracked as a non-blocking live-infra axis | [phase-7-aws-substrate-foundations.md](phase-7-aws-substrate-foundations.md) provisioning — the AWS-substrate run (EBS `volumeHandle` rebind, exercising Sprints `7.28` + `4.39`/`4.40`) is a parity-coverage row. **`Live-proof: pending`** while it needs a deployed EKS cluster with static retained EBS PVs; non-blocking per Standard O, and never marks Sprint `5.12` or phase 5 ⏸️ Blocked |

The sealed-Vault validation is **built and proven once** (no change to what is built or
proven): the home-substrate run is the phase-5 Sprint `5.8` suite-content deliverable, and
the identical validation's AWS-substrate run is phase-7-owned live-proof coverage tracked
only in this section's table — it does not gate, block, or reopen Sprint `5.8` or phase 5.

## Canonical Suite Composition (Substrate-Agnostic)

The full inventory of named validations and their dispatch lives in
[phase-5-canonical-test-suite.md](phase-5-canonical-test-suite.md) and
[system-components.md](system-components.md). Substrates do not contribute or remove validations;
they only stand up or tear down the substrate that the suite runs against.

Current deployment qualification is not derived from this composition statement. It remains
`pending` for both substrates until the Standard P ledger in `README.md` records exact-revision
evidence.

## Related Documents

- [development_plan_standards.md](development_plan_standards.md)
- [README.md](README.md)
- [00-overview.md](00-overview.md)
- [system-components.md](system-components.md)
- [phase-5-canonical-test-suite.md](phase-5-canonical-test-suite.md)
- [phase-7-aws-substrate-foundations.md](phase-7-aws-substrate-foundations.md)
- [phase-8-email-invite-auth.md](phase-8-email-invite-auth.md)
- [../documents/engineering/lifecycle_control_plane_architecture.md](../documents/engineering/lifecycle_control_plane_architecture.md) — physical roles, capability algebra, durable authority/outbox, local gateway journals, and cleanup DAG
- [../documents/engineering/vault_doctrine.md](../documents/engineering/vault_doctrine.md) — the finalized, fail-closed Vault secret-management root both substrates run
- [../documents/engineering/cluster_federation_doctrine.md](../documents/engineering/cluster_federation_doctrine.md) — the Vault transit-seal trust tree governing root/child cluster federation
