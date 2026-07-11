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
Every secret/credential/key/cert is a Vault object (KV v2, Transit, or PKI), with no second store and
no plaintext fallback; a sealed (or unreachable/uninitialized) Vault **bricks** whichever substrate
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
Vault transit-seal trust tree, parent custody of child init keys, and downstream-cluster inventory as
secret data — is governed by
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
| Inventory | Local RKE2 cluster on the operator host, MetalLB L2/BGP, Envoy Gateway, cert-manager (real ZeroSSL), Keycloak, Patroni-backed Postgres via the Percona operator, the supported `gateway`, `keycloak`, `vscode`, `api`, and `websocket` charts |
| Required Config | `route53.zone_id`, `domain.demo_fqdn`, `acme.*` (ZeroSSL `server`, account email, ZeroSSL EAB key id + hmac key), `deployment.*`, `ses.*` (sender_domain, receive_subdomain, capture_bucket — required for `keycloak-invite` validation). Elevated/admin AWS power enters prodbox only through the interactive `SecretRef.Prompt`; under the harness the test-only `aws_admin_for_test_simulation.*` fixture in `test-secrets.dhall` (TestPlaintext, never imported by production config, never in Vault) simulates that prompt for the shared IAM harness and long-lived teardown/provisioning flows. Missing any required field fails fast; the home substrate does not fall back to AWS-substrate values. |
| Prerequisites satisfied | `platform_linux`, `systemd_available`, `supported_ubuntu_2404`, `machine_identity`, `tool_*`, `settings_*`, `aws_iam_harness_ready`, `kubeconfig_*`, `rke2_*`, `k8s_*`, `pulumi_logged_in`, `infra_ready`, `gateway_daemon_acquire`, `aws_credentials_valid`, `route53_*` |
| Phase ownership (provision/teardown) | [phase-4-lifecycle-canonical-paths.md](phase-4-lifecycle-canonical-paths.md) |
| Suite parity | 🧪 **Code-owned current membership closed; live proof pending.** Sprints `1.60`, `2.31`, `3.25`, `4.47`, `5.16`, `5.17`, and `8.10` have landed the runtime-memory plan, bounded gateway runtime, constant-time chart probes, safe registered retained-SES transaction, absorbing suite-stability oracle, capability-derived selected-target preparation, and exact semantic SES readiness. Earlier public-edge, ZeroSSL, OIDC, WebSocket, and Route 53 proofs remain historical evidence; fresh AWS identity/DKIM/MX/rule propagation and a deployed home invite aggregate through the new gate remain non-blocking Standard-O axes. |
| Notes | The home cluster is both the production runtime for the Haskell gateway daemon and a substrate for the canonical test suite. The same chart deploys serve both roles. |

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
| Inventory today | Three per-run Pulumi stacks: registry `aws-eks` / Pulumi stack id `aws-eks-test` (a dedicated, non-default VPC; `prodbox.io/managed-by=prodbox` tagged VPC/IGW/route-table/subnets; EKS cluster; node group; IAM; security group), `aws-eks-subzone` (delegated Route 53 hosted subzone), and `aws-test` (VPC, subnets, three EC2 instances, security group, key pair). State is stored as opaque Model-B objects in the in-cluster MinIO `prodbox-state` bucket and accessed from the host through the daemon object-store API (Sprint `7.30`). Sprint `7.29` pins the fresh-EKS-VPC guarantee to the existing destroy-before-ensure residue purge. |
| Target inventory | Same canonical service set as the home substrate (Sprint 7.12 substrate equivalence): cert-manager + real ZeroSSL, Envoy Gateway, the in-cluster registry (`registry:2`) + MinIO + the Percona PostgreSQL operator, Keycloak, Patroni Postgres, `gateway`, `keycloak-postgres`, `vscode`, `api`, `redis`, `websocket`. The registry + MinIO + Percona are installed on **both** substrates — the AWS registry is the EKS-side registry reached through the node-local registry proxy (the EKS containerd registry-mirror DaemonSet that makes `127.0.0.1:30080/prodbox/...` resolve on EKS, mirroring the home NodePort-on-`127.0.0.1` pattern). The two substrates differ only in their LOWER layer: ingress load-balancer (MetalLB on home, the AWS Load Balancer Controller / NLB on EKS), Route 53 hosting (parent zone on home, the per-substrate subzone provisioned by `pulumi/aws-eks-subzone/` on AWS), and the block-storage volume source (`hostPath` under `.data/` on home, pre-created EBS lifted in as static `Retain` PVs on EKS — same static no-provisioner discipline, Sprint `7.28`). |
| Required Config | `aws_substrate.subzone_name` (the AWS-substrate public FQDN, e.g. `aws.test.resolvefintech.com`), optional `aws_substrate.hosted_zone_id` when an operator wants to pin the already-provisioned subzone ID in config, `ses.*` (sender_domain, receive_subdomain, capture_bucket — shared cross-substrate; same values as home substrate), AWS operator credentials, plus the same `acme.*` settings the home substrate uses. During harness-driven AWS runs, the suite reads the live `aws-eks-subzone` Pulumi output after provisioning and passes the hosted-zone ID to child commands. Missing AWS-substrate values fail fast; the AWS substrate does not fall back to `route53.zone_id` or `domain.demo_fqdn` from the home substrate. |
| Prerequisites satisfied today | `aws_credentials_valid`, `route53_accessible`, `route53_lifecycle_capable`, `pulumi_logged_in`, the AWS-stack snapshot prereqs |
| Phase ownership (provision/teardown) | [phase-7-aws-substrate-foundations.md](phase-7-aws-substrate-foundations.md) |
| Suite parity | 🧪 **Code-owned parity closed; aggregate live proof pending.** Phase `7`'s substrate-owned code and the then-canonical June slice remain proven. Sprints `1.60`, `2.31`, `3.25`, `4.47`, `5.16`, `5.17`, and `8.10` have landed the representable runtime-memory plan, bounded gateway runtime, constant-time chart probes, safe registered retained-SES transaction, absorbing stability evidence, capability-derived selected-target preparation, and exact semantic SES gate shared with home. Phase `7` remains closed under Standard N. Fresh AWS identity/DKIM/MX/rule propagation and the full deployed `prodbox test all --substrate aws` invite path remain non-blocking Standard-O live-proof axes. |
| Notes | The AWS substrate is exclusively a test substrate. There is no production EKS cluster that `prodbox` manages. The literal stack names (`aws-eks-test`, `aws-test`) reflect that. |

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
| `aws-eks` | `prodbox aws stack eks reconcile` (and implicitly by `prodbox test all` / `prodbox test integration … --substrate aws` when needed) | `prodbox aws stack eks destroy --yes`; auto-destroyed by the test-harness postflight on success, failure, **and** Ctrl-C (Sprint `7.6`); also destroyed by `prodbox cluster delete --cascade` (Sprint `4.11`) | Opaque Model-B objects in the in-cluster MinIO `prodbox-state` bucket, accessed from the host through the daemon object-store API (Sprint `7.30`) |
| `aws-eks-subzone` | `prodbox aws stack aws-subzone reconcile` | `prodbox aws stack aws-subzone destroy --yes`; auto-destroyed by the test-harness postflight (Sprint `7.6`); also destroyed by `prodbox cluster delete --cascade` (Sprint `4.11`); destroy deletes non-NS/SOA records first so a failed run's A record cannot keep the hosted zone non-empty | Opaque Model-B objects in MinIO, accessed through the daemon object-store API |
| `aws-test` (HA-RKE2 EC2) | `prodbox aws stack test reconcile` | `prodbox aws stack test destroy --yes`; auto-destroyed by the test-harness postflight (Sprint `7.6`); also destroyed by `prodbox cluster delete --cascade` (Sprint `4.11`) | Opaque Model-B objects in MinIO, accessed through the daemon object-store API |

Per-run stacks exist only for the lifetime of a suite run that needs them. The harness owns
the full create/destroy lifecycle; operators do not normally invoke the destroy commands by
hand because the harness already does so on every exit path. Pulumi state for these stacks
lives in MinIO on the retained home/control-plane `.data` volume so an interrupted run can still
be observed and destroyed after cluster rebuild. The harness, not loss of the cluster, ends the
AWS resource lifetime and prunes the checkpoint after successful destruction.

### Long-lived cross-substrate shared infrastructure (retained by design)

| Resource | Provisioned by | Destroyed by | Pulumi state backend |
|----------|----------------|--------------|----------------------|
| `aws-ses` stack (sending identity, DKIM, MX, receive rule set, S3 capture bucket, SMTP IAM user) | `prodbox aws stack aws-ses reconcile`; landed Sprint `5.17` also selects the same idempotent registered ensure whenever `ValidationKeycloakInvite` is present | `prodbox aws stack aws-ses destroy --yes` — **only on explicit invocation**; never auto-destroyed by the test-harness postflight, never destroyed by `prodbox cluster delete` (any flag); destroyed transitively by `prodbox nuke` (Sprint `4.13`) | Opaque Model-B checkpoint in the retained home/control-plane `prodbox-state` + Vault keyspace, addressed through an explicit `LongLivedCheckpointAuthority`; never through the active target substrate |
| Long-lived `pulumi_state_backend` S3 bucket (Sprint `4.10`) | `ensureLongLivedPulumiStateBucket` in `src/Prodbox/Infra/LongLivedPulumiBackend.hs` when retained TLS or legacy first-touch state requires it (idempotent, admin-credentialed) | `prodbox nuke` (Sprint `4.13`) — final pass after all long-lived stacks are gone; never destroyed by `aws teardown` or `cluster delete` | n/a; this is retained public-edge TLS storage and an optional legacy `aws-ses` import source, not the primary current Pulumi checkpoint backend |
| Operator-owned Route 53 parent zone for the configured public FQDN | Operator-managed in Route 53 (no `prodbox aws stack` flow) | Operator action against Route 53 — outside the harness surface | n/a |
| Public-edge TLS certificate material (Sprints `4.24`/`7.11`/`8.7`) | cert-manager via the ZeroSSL ACME `ClusterIssuer` (`zerossl-dns01`); retained material written to a substrate-scoped key (`public-edge-tls/<substrate>/<fqdn>`) in the long-lived `pulumi_state_backend` S3 bucket and restored before every issuance | `prodbox nuke` only; never destroyed by `aws teardown` or `cluster delete`; registered as a `LongLived` managed resource (Sprint `4.24`) | Long-lived `pulumi_state_backend` S3 bucket |

Retained by design — not orphaned. SES domain identity + DKIM verification requires 5–30 min
of DNS propagation per provision; only one receive rule set may be active per AWS account; S3
bucket names have a ~24-hour reuse cooldown; and re-ordering the public-edge ZeroSSL certificate
on every rebuild would needlessly consume ZeroSSL issuance quota — the TLS analogue of the SES
cooldown — so the public-edge certificate is issued once and restored from the long-lived S3
store on every rebuild rather than re-ordered. Per-run re-provision is impractical at suite
cadence. The harness explicitly carves these resources out of postflight auto-destroy so
operators can run the suite at a sane cadence without rebuilding shared infrastructure each
time. Retention controls teardown only: an invite-capable suite still ensures the desired-present
stack and then retains it. The current `aws-ses` checkpoint is a Model-B object under the retained
home/control-plane `prodbox-state` and Vault keyspace. Its authority is distinct from the
`TargetClusterSecretSink` where SMTP KV is written for the selected substrate. The configured
long-lived S3 store retains public-edge TLS material and may supply a legacy SES checkpoint on
first touch; it is not the primary current stack backend. If the Model-B checkpoint is missing or
corrupt while fixed-name AWS resources are positively observed, the implemented desired-present
planner chooses explicit import/repair rather than create; positively absent resources choose an
explicit create action. The lease, target-intent, SMTP-key-repair, and fenced-checkpoint modules
implement the Model-B protocol, and unobservable AWS or checkpoint state never lowers to
absence/missing. Sprint `4.47` composes them in the canonical ensure path under fixed-role sessions
and a release-aware predecessor recovery boundary.

When an operator wants the long-lived resources gone (e.g., decommissioning the project or
account), the supported path is the explicit destroy command in the table above, or the
operator-only `prodbox nuke` for total teardown. There is no "managed-by-someone-else"
category — the harness still owns the create/destroy lifecycle; it simply does not invoke
destroy on its own for this class.

### K8s-controller-created AWS resources (cluster-tagged)

| Resource | Created by | Tag signature | Destroyed by |
|----------|------------|---------------|--------------|
| EBS volumes for PVCs (superseded → pre-created `Retain`) | **Historically** the EBS CSI driver dynamically responded to `PersistentVolumeClaim` resources. Sprint `7.28` replaced this with **pre-created EBS volumes lifted in as static `Retain` PVs** — a registered managed resource (typed `discover`/`destroy`, Sprint `4.39`), no longer controller-created. | `prodbox.io/managed-by: prodbox` + a retain-vs-test-scoped marker (test volumes also `kubernetes.io/cluster/<cluster-name>: owned`) | Retained on teardown (`Retain`, not Pulumi-owned); test-scoped volumes deleted by the suite postflight reaper (Sprint `4.40`) — **not** the drain. The dynamic path is in [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md) Completed. |
| ALBs / NLBs / target groups / security groups | AWS Load Balancer Controller responding to `Service type=LoadBalancer` and `Ingress` resources | `kubernetes.io/cluster/<cluster-name>: owned`, `elbv2.k8s.aws/cluster`, `ingress.k8s.aws/stack` | K8s drain phase (Sprint `4.12`); fallback postflight tag sweep |
| Route 53 TXT records (`_acme-challenge.*`) | cert-manager DNS01 solver | Record-name pattern `_acme-challenge.*.<configured public FQDN>` | K8s drain phase (Sprint `4.12`) by deleting `Certificate` resources first; fallback postflight tag sweep |
| Route 53 A records for DNS bootstrap | Direct `aws` CLI subprocess in `src/Prodbox/CLI/Rke2.hs:2484` and `src/Prodbox/TestValidation.hs:1547` | None reliably; identified by content (configured public FQDN) | Best-effort cleanup paths in the same modules; fallback postflight tag sweep |

These resources are **not** Pulumi-tracked. They are created by Kubernetes operators or by
direct AWS API calls from the harness and survive Pulumi-stack destruction unless drained
first. The leak class is owned by the K8s drain phase in Sprint `4.12` plus the postflight
tag sweep that fails any destructive lifecycle command if cluster-tagged resources survive;
see
[../documents/engineering/lifecycle_reconciliation_doctrine.md](../documents/engineering/lifecycle_reconciliation_doctrine.md).

### Fixed-name IAM orphan residue (harness preflight residual class)

| Resource | Origin | Why it orphans | Cleanup owner |
|----------|--------|----------------|---------------|
| `aws-eks-test-aws-lb-controller` policy/role and `aws-eks-test-ebs-csi-driver` role (fixed-name) | The `aws-eks` Pulumi program (per-run) | A `pulumi up` partially succeeds (IAM created early), then its state is lost — the create-then-crash window, or a `.data/` wipe / cluster crash before the per-run `pulumi destroy` | Harness preflight, scoped to these exact names and only when the authoritative `aws-eks-test` Pulumi checkpoint is absent |
| auto-named `clusterRole-*` / `nodeRole-*` | The `aws-eks` Pulumi program (per-run) | Same create-then-crash window, but names are provider-assigned and cannot be reaped safely without broader IAM scanning | Operator investigation; do not add a broad automatic IAM sweep |
| Operational `prodbox` IAM user + access key + `prodbox-inline` policy | `prodbox aws setup` / the test-harness IAM bootstrap | An interrupted run leaves it; `rke2 delete` does not own it (`aws teardown` / the harness postflight does) | `prodbox aws teardown`, or operator via `aws iam delete-user` |

The AWS Resource Groups Tagging API does not return IAM resources, so the postflight tag sweep
cannot see this class (see
[lifecycle_reconciliation_doctrine.md § 6a](../documents/engineering/lifecycle_reconciliation_doctrine.md)).
The supported automation is intentionally narrow: `runAwsIamHarnessSetup` checks the
authoritative per-run `aws-eks-test` Pulumi checkpoint first, then deletes only the two
fixed-name IRSA roles and the fixed-name AWS Load Balancer Controller policy. If the policy is
attached to anything outside that exact harness-owned role set, the preflight fails loud instead
of detaching it. Broad IAM name scanning remains forbidden because it would mask genuine logical
leaks and could cross ownership boundaries.

### Operational resources (registered, ephemeral per run)

| Resource | Created by | Discover | Destroyed by |
|----------|------------|----------|--------------|
| Fixed `prodbox-ses-lease-session` IAM role (+ exact inline policy) | `prodbox aws setup` / `prodbox config setup` / the test-harness IAM bootstrap when the public SES scope is configured | typed `iam get-role` + `iam get-role-policy` observation in `Prodbox.Infra.AwsSesLeaseRole` | `prodbox aws teardown` (`reconcileAbsent`, before the trusted user, followed by authoritative absence re-observation) |
| Operational `prodbox` IAM user (+ access key + `prodbox-inline` policy) | `prodbox aws setup` / the test-harness IAM bootstrap | `aws iam get-user` | `prodbox aws teardown` (`reconcileAbsent`) |
| Generated operational `prodbox` `aws.*` credential in Vault KV (`secret/gateway/gateway/aws`) | `prodbox aws setup` minting the dedicated least-privilege identity, after Vault is unsealed, using the ephemeral elevated credential supplied at the interactive `SecretRef.Prompt` (the harness simulates that prompt from `aws_admin_for_test_simulation.*` in `test-secrets.dhall`); production config carries only the `SecretRef.Vault` reference, never the plaintext key | vault-kv-present | `prodbox aws teardown` (`reconcileAbsent`) |

These are **registered `Operational`-class resources** in the managed-resource registry
(Phase `4` Sprints `4.20`/`4.47` and Phase `7` Sprint `7.8`). Before the registry they
were created by `aws setup` with no registered discover/destroy, which is why an interrupted
run leaked both undetected. The registry gives each a `discover` + `destroy` so `aws teardown`'s
`reconcileAbsent` pass reconciles them like any other resource.

### Lifecycle ownership rule

No new AWS or cluster resource type may be added by any `prodbox` code path without a
corresponding **managed-resource registry** entry (typed `discover` + `destroy`, with a
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
| AWS SES sending identity (domain) | Operator AWS account | Lifecycle/planning: [phase-4](phase-4-lifecycle-canonical-paths.md) / [phase-5](phase-5-canonical-test-suite.md); semantics: [phase-8](phase-8-email-invite-auth.md) | `prodbox aws stack aws-ses reconcile` / `prodbox aws stack aws-ses destroy --yes` — `pulumi/aws-ses/`; landed Sprint `5.17` invokes the same idempotent registered ensure whenever `ValidationKeycloakInvite` is selected | Both substrates running `ValidationKeycloakInvite` |
| AWS SES receive subdomain + MX records + receive rule set + S3 capture bucket | Operator AWS account | Lifecycle/planning: [phase-4](phase-4-lifecycle-canonical-paths.md) / [phase-5](phase-5-canonical-test-suite.md); semantics: [phase-8](phase-8-email-invite-auth.md) | Same canonical reconcile/destroy surface; Sprint `8.10` proves exact identity, DKIM, MX, active/enabled rule/action target, and Pulumi-owned capture-canary list/get capability before SMTP/chart mutation | Both substrates running `ValidationKeycloakInvite` |
| SMTP IAM user + access key for Keycloak SES SMTP | Operator AWS account | Lifecycle/planning: [phase-4](phase-4-lifecycle-canonical-paths.md) / [phase-5](phase-5-canonical-test-suite.md); semantics: [phase-8](phase-8-email-invite-auth.md) | Same canonical reconcile/destroy surface (`ses:SendRawEmail` + capture-bucket read/delete); landed Sprint `5.17` reconciles through `LongLivedCheckpointAuthority`, then writes `secret/keycloak/smtp` only through the selected `TargetClusterSecretSink` | Keycloak chart `smtpServer` block; native `ValidationKeycloakInvite` harness |

## Per-Validation Substrate Coverage Notes

The substrate `Suite parity` rows above track aggregate canonical-suite coverage per
substrate. Individual validations whose AWS-substrate coverage is on a separate axis from
their home-substrate suite-content closure are called out here, per the orthogonality rule
above and [development_plan_standards.md → N / O](development_plan_standards.md#n-phase-independence-no-backward-blocking).

| Validation | Home-substrate suite-content closure (owned surface) | AWS-substrate coverage (owned surface) |
|------------|------------------------------------------------------|----------------------------------------|
| Gateway runtime stability (bounded-memory/restart/OOM/high-water proof) | [phase-5-canonical-test-suite.md](phase-5-canonical-test-suite.md) Sprint `5.16` — Done: `gateway-pods` folds run-wide absorbing unhealthy evidence plus a separately restartable three-sample healthy window; point Deployment readiness is not stability. Thresholds derive from the landed Sprint `1.60` plan and the recorder spans compiled home restore/lifecycle/postflight rollouts. | The identical typed validation targets EKS and the recorder begins after the compiled AWS gateway reconcile. The live AWS soak is a non-blocking Standard-O axis; it does not reopen Phase `7`. |
| `keycloak-invite` retained-SES preparation and semantic readiness | [phase-5-canonical-test-suite.md](phase-5-canonical-test-suite.md) Sprint `5.17` — Done over completed Sprint `4.47`; the plan derives SES need from invite capability, proves the selected target gateway edge, invokes the registered bracketed ensure, syncs SMTP, and retains the stack. [phase-8](phase-8-email-invite-auth.md) Sprint `8.10` is Done: the provider-first transaction polls exact configured identity/DKIM/MX/rule/action/capture semantics, retries only `Pending`, and cannot reach SMTP mutation after timeout or terminal evidence. | The same capability-derived plan uses the retained control-plane checkpoint authority and the AWS target-cluster secret sink. Fresh AWS identity/DKIM/MX/rule propagation and deployed home/AWS invite aggregates are non-blocking Standard-O axes. |
| Sealed-Vault validation (the fail-closed sealed/unreachable/uninitialized-Vault proof) | [phase-5-canonical-test-suite.md](phase-5-canonical-test-suite.md) Sprint `5.8` — Done on its code-owned surface once the validation exists and passes on the home substrate (`prodbox dev check`, `test unit`, `test integration cli/env`); phase-5 closure depends on this axis only | [phase-7-aws-substrate-foundations.md](phase-7-aws-substrate-foundations.md) provisioning — the AWS-substrate run of the same validation is a parity-coverage row owned by phase 7. **`Live-proof: pending`** while it needs a deployed EKS cluster + an unsealed in-cluster Vault; non-blocking per Standard O, and never marks Sprint `5.8` or phase 5 ⏸️ Blocked |
| `resource-guardrails` (cpu/memory/storage request-limit and quota proof) | [phase-5-canonical-test-suite.md](phase-5-canonical-test-suite.md) Sprint `5.13` — Done on its code-owned surface: the named validation, command parser/registry, planner ordering, topology mapping, pod/quota/limit-range JSON oracle, and fake-`kubectl` integration proof are implemented and locally validated; the optional real over-limit pod stress proof is tracked as a non-blocking live-infra axis | AWS-substrate run of the same validation is a parity-coverage row once the AWS substrate is provisioned. **`Live-proof: pending`** while it needs a deployed EKS cluster with the resource-governed chart set; non-blocking per Standard O and never a backward block on Phase `5` |
| `daemon-bootstrap` (post-bootstrap daemon transport proof) | [phase-5-canonical-test-suite.md](phase-5-canonical-test-suite.md) Sprint `5.14` — Done on its code-owned surface: the named validation, command parser/registry, planner ordering, topology mapping, route/transport/redaction oracle, and built-frontend pass/fail trace proof are implemented and locally validated | AWS/Pulumi object-store parity composes with [phase-7-aws-substrate-foundations.md](phase-7-aws-substrate-foundations.md) Sprint `7.30`, now Done on its code-owned surface. **`Live-proof: pending`** for the real EKS/MinIO daemon object-store run; non-blocking per Standard O and never a backward block on Phase `5` |
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

## Related Documents

- [development_plan_standards.md](development_plan_standards.md)
- [README.md](README.md)
- [00-overview.md](00-overview.md)
- [system-components.md](system-components.md)
- [phase-5-canonical-test-suite.md](phase-5-canonical-test-suite.md)
- [phase-7-aws-substrate-foundations.md](phase-7-aws-substrate-foundations.md)
- [phase-8-email-invite-auth.md](phase-8-email-invite-auth.md)
- [../documents/engineering/vault_doctrine.md](../documents/engineering/vault_doctrine.md) — the finalized, fail-closed Vault secret-management root both substrates run
- [../documents/engineering/cluster_federation_doctrine.md](../documents/engineering/cluster_federation_doctrine.md) — the Vault transit-seal trust tree governing root/child cluster federation
