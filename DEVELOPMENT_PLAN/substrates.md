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
[../documents/engineering/acme_provider_guide.md](../documents/engineering/acme_provider_guide.md)
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
   into `prodbox check-code`) fails closed on any shared-component chart-version / image
   re-pinned with a literal on a per-substrate branch; the single `Prodbox.ContainerImage` value
   is the only sanctioned source. The genuinely substrate-specific LOWER layer (the AWS Load
   Balancer Controller on AWS, MetalLB + FRR on home, the EKS node-local registry proxy) is
   exempt — those have no cross-substrate counterpart to keep in lockstep.
3. **A shared `[PlatformComponent]` inventory + coverage test.**
   `Prodbox.ContainerImage.sharedPlatformComponents` declares the shared set once (`gateway`,
   `keycloak`, `keycloak-postgres`, `vscode`, `api`, `redis`, `websocket`, MinIO, Harbor, the
   Percona operator, Envoy Gateway, cert-manager, ZeroSSL DNS01). A `test/unit/Main.hs` coverage
   test asserts both installers (`homeSubstratePlatformComponents` in `Prodbox.CLI.Rke2`,
   `awsSubstratePlatformComponents` in `Prodbox.Lib.AwsSubstratePlatform`) cover every entry. It
   is **not** a unified step DAG — each substrate keeps its own ordering and its own lower-layer
   implementation — but neither installer may silently drop a shared component.

Harbor + MinIO + the Percona operator are therefore installed on **both** substrates; the AWS
substrate is **not** a "no-Harbor" cluster. When AWS appears to be "missing" a shared platform
piece the home cluster has, the fix is to extend the shared inventory and the AWS installer,
never to render different image refs or re-pin versions per substrate.

## Substrate Inventory

### Home Local Substrate

| Field | Value |
|-------|-------|
| Provision | `prodbox rke2 reconcile` followed by `prodbox charts deploy <chart>` for the canonical chart set |
| Teardown | `prodbox rke2 delete --yes` (preserves retained host roots per the lifecycle doctrine) |
| Inventory | Local RKE2 cluster on the operator host, MetalLB L2/BGP, Envoy Gateway, cert-manager (real ZeroSSL), Keycloak, Patroni-backed Postgres via the Percona operator, the supported `gateway`, `keycloak`, `vscode`, `api`, and `websocket` charts |
| Required Config | `route53.zone_id`, `domain.demo_fqdn`, `acme.*` (ZeroSSL `server`, account email, ZeroSSL EAB key id + hmac key), `deployment.*`, `ses.*` (sender_domain, receive_subdomain, capture_bucket — required for `keycloak-invite` validation), `aws_admin_for_test_simulation.*` (for the shared IAM harness and long-lived teardown/provisioning flows). Missing any required field fails fast; the home substrate does not fall back to AWS-substrate values. |
| Prerequisites satisfied | `platform_linux`, `systemd_available`, `supported_ubuntu_2404`, `machine_identity`, `tool_*`, `settings_*`, `aws_iam_harness_ready`, `kubeconfig_*`, `rke2_*`, `k8s_*`, `pulumi_logged_in`, `infra_ready`, `gateway_daemon_acquire`, `aws_credentials_valid`, `route53_*` |
| Phase ownership (provision/teardown) | [phase-4-lifecycle-canonical-paths.md](phase-4-lifecycle-canonical-paths.md) |
| Suite parity | ✅ Full canonical suite, including the public-edge proofs that exercise real ZeroSSL certs, real OIDC redirects through Keycloak, real WebSocket fan-out, and the configured public Route 53 record on `test.resolvefintech.com` |
| Notes | The home cluster is both the production runtime for the Haskell gateway daemon and a substrate for the canonical test suite. The same chart deploys serve both roles. |

### AWS Substrate

| Field | Value |
|-------|-------|
| Provision | `prodbox pulumi eks-resources` (EKS test cluster), `prodbox pulumi aws-subzone-resources` (per-substrate Route 53 subzone), and `prodbox pulumi test-resources` (three Ubuntu 24.04 EC2 instances for HA-RKE2) |
| Teardown | `prodbox pulumi eks-destroy --yes`, `prodbox pulumi aws-subzone-destroy --yes`, and `prodbox pulumi test-destroy --yes` |
| Inventory today | Two disposable Pulumi stacks: `aws-eks-test` (VPC, subnets, EKS cluster, node group, IAM, security group) and `aws-test` (VPC, subnets, three EC2 instances, security group, key pair). State stored in MinIO-backed Pulumi backend on the local cluster under `prodbox-test-pulumi-backends`. |
| Target inventory | Same canonical service set as the home substrate (Sprint 7.12 substrate equivalence): cert-manager + real ZeroSSL, Envoy Gateway, Harbor + MinIO + the Percona PostgreSQL operator, Keycloak, Patroni Postgres, `gateway`, `keycloak-postgres`, `vscode`, `api`, `redis`, `websocket`. Harbor + MinIO + Percona are installed on **both** substrates — the AWS Harbor is the EKS-side Harbor reached through the node-local registry proxy (the EKS containerd registry-mirror DaemonSet that makes `127.0.0.1:30080/prodbox/...` resolve on EKS, mirroring the home NodePort-on-`127.0.0.1` pattern). The two substrates differ only in their LOWER layer: ingress load-balancer (MetalLB on home, the AWS Load Balancer Controller / NLB on EKS) and Route 53 hosting (parent zone on home, the per-substrate subzone provisioned by `pulumi/aws-eks-subzone/` on AWS). |
| Required Config | `aws_substrate.subzone_name` (the AWS-substrate public FQDN, e.g. `aws.test.resolvefintech.com`), optional `aws_substrate.hosted_zone_id` when an operator wants to pin the already-provisioned subzone ID in config, `ses.*` (sender_domain, receive_subdomain, capture_bucket — shared cross-substrate; same values as home substrate), AWS operator credentials, plus the same `acme.*` settings the home substrate uses. During harness-driven AWS runs, the suite reads the live `aws-eks-subzone` Pulumi output after provisioning and passes the hosted-zone ID to child commands. Missing AWS-substrate values fail fast; the AWS substrate does not fall back to `route53.zone_id` or `domain.demo_fqdn` from the home substrate. |
| Prerequisites satisfied today | `aws_credentials_valid`, `route53_accessible`, `route53_lifecycle_capable`, `pulumi_logged_in`, the AWS-stack snapshot prereqs |
| Phase ownership (provision/teardown) | [phase-7-aws-substrate-foundations.md](phase-7-aws-substrate-foundations.md) |
| Suite parity | ✅ Phase 7-owned AWS substrate parity proved live on June 5, 2026. The supported `Substrate` ADT, `--substrate {home-local\|aws}` CLI surface, EKS kubeconfig materialization, per-substrate Route 53 subzone, cert-manager DNS01, EKS-side Harbor/MinIO/Percona, AWS-specific Envoy Gateway runtime, AWS chart values, and public-edge diagnostics are wired. The June 5 AWS runs proved AWS public DNS reconciles to the Envoy NLB target, postflight destroys `aws-eks-subzone`, `aws-eks`, and `aws-test` with residue checks passing, home-Harbor login retry no longer blocks runtime restore, the Keycloak public-token-endpoint readiness gate completes, `charts-vscode --substrate aws` returns the expected OIDC redirect, `charts-api` / `charts-websocket` pass with in-cluster Keycloak JWKS backchannels, Harbor/MinIO admin HTTPRoutes and SecurityPolicies are installed on the AWS subzone host, and destructive `ValidationLifecycle` succeeds under the harness. The June 6 targeted `keycloak-invite --substrate aws` run also passes invite capture/link-follow with `ValidationKeycloakInvite` before destructive validations, the selected substrate public FQDN, the `/auth/admin` public route, `aws_admin_for_test_simulation.*` credential materialization, fresh-cluster SMTP sync, and the ZeroSSL ACME path. Sprint `8.5` credential-setup/OIDC claim assertions plus local SMTP Secret / preserved-realm reconciliation, SMTP NetworkPolicy, verify-email continuation, public-edge certificate status-patch guard, and public-edge TLS Secret retention are now wired and unit-tested. The live POST/OIDC substrate proof landed 2026-06-09: targeted `keycloak-invite --substrate aws` passed end-to-end (`OIDC_CLAIMS_VERIFIED=true` on `aws.test.resolvefintech.com`, clean EKS/subzone/test teardown, no leak), so `keycloak-invite` is ✅ on **both** substrates, and the Sprint `8.8` certificate round-trip restore-no-reorder is proven (a rebuild restores the cert from the long-lived S3 store and cert-manager adopts it with zero new ACME orders). The full AWS aggregate (`prodbox test all --substrate aws`) then closed ✅ green on 2026-06-09 (`TESTALL_AWS_EXIT=0`): all 16 canonical validations on EKS including `keycloak-invite` and the destructive `lifecycle`, both cabal suites (unit 695, integration 32), and a clean per-run teardown with no leak — so the complete canonical suite is now green on both substrates. The final Sprint 8.8 deliverable — the `prodbox nuke` nuke-only-removes-the-retained-cert proof — then closed via the interactive integration harness (three new `CliSuite.hs` cases drive `prodbox nuke` through the `PRODBOX_ALLOW_NON_TTY_INTERACTIVE` + stdin seam: the typed-confirmation gate, the `--dry-run` step-5 long-lived bucket destroy where the cert lives, and the full five-step total teardown end-to-end on `NUKE EVERYTHING`), which with the Sprint 4.24 `LongLived` classification completes the proof. Phase 8 is now ✅ Done. |
| Notes | The AWS substrate is exclusively a test substrate. There is no production EKS cluster that `prodbox` manages. The literal stack names (`aws-eks-test`, `aws-test`) reflect that. |

## Resource Lifecycle Classes

Every AWS resource any `prodbox` flow creates falls into exactly one of three lifecycle classes.
This section is the authoritative classification — when adding a new AWS resource to any
`prodbox` code path, it must land in one of these three classes (and in the matching inventory
table below). Pulumi state lifetime must also match resource lifetime per class; see
[../documents/engineering/lifecycle_reconciliation_doctrine.md → §2 State-Lifetime Rule](../documents/engineering/lifecycle_reconciliation_doctrine.md).

The per-run vs long-lived partition is mirrored in code by `Prodbox.Aws.perRunStackNames`
and `Prodbox.Aws.longLivedStackNames` (Sprint `7.7`), which the
`Prodbox.Aws.partitionResidueByLifecycle` predicate and the `PulumiResiduePolicy`
`BypassPerRunResidueOnly` arm consume. The `prodbox aws teardown` flag surface
(`--destroy-pulumi-residue`, `--allow-pulumi-residue`) and the harness-internal
`BypassPerRunResidueOnly` mode both depend on the partition being authoritative here.

The registry SSoT is `Prodbox.Lifecycle.ResourceClass.resourceLifecycleClasses` (Sprint
`4.20`); `perRunStackNames` / `longLivedStackNames` are derived from it. The table below is
**generated** from that registry by `prodbox docs generate` (Sprint `4.22`) — do not hand-edit
between the markers; `prodbox docs check` fails the build if it drifts from the code, so a new
resource cannot be added to the registry without this inventory updating in lockstep:

<!-- prodbox:resource-lifecycle-classes:start -->
| Resource | Lifecycle class |
|----------|-----------------|
| `aws-eks` | PerRun |
| `aws-eks-subzone` | PerRun |
| `aws-test` | PerRun |
| `aws-ses` | LongLived |
| `public-edge-tls` | LongLived |
| `operational-iam-user` | Operational |
| `operational-aws-config` | Operational |
<!-- prodbox:resource-lifecycle-classes:end -->

Each Pulumi-managed substrate stack is described by one `StackDescriptor` SSoT record
(`Prodbox.Infra.StackDescriptor`, Sprint `4.27`): its registry name, Pulumi stack id, project
subdir under `pulumi/`, CLI verb stem, and lifecycle class. The per-run name list
(`Prodbox.Aws.perRunStackNames`), the CLI verbs, and the project dirs are **derived** from it
rather than hand-maintained, removing the drift the documentation-harmony audit flagged between
the registry names, the CLI verbs, and the project directories. The registry-name↔CLI-command
table below is **generated** from `stackDescriptors` by `prodbox docs generate` — do not hand-edit
between the markers; `prodbox docs check` fails the build if it drifts. This is the typed source
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
| `aws-eks` | `prodbox pulumi eks-resources` (and implicitly by `prodbox test all` / `prodbox test integration … --substrate aws` when needed) | `prodbox pulumi eks-destroy --yes`; auto-destroyed by the test-harness postflight on success, failure, **and** Ctrl-C (Sprint `7.6`); also destroyed by `prodbox rke2 delete --cascade` (Sprint `4.11`) | MinIO in-cluster (`s3://prodbox-test-pulumi-backends?endpoint=127.0.0.1:39000`) |
| `aws-eks-subzone` | `prodbox pulumi aws-subzone-resources` | `prodbox pulumi aws-subzone-destroy --yes`; auto-destroyed by the test-harness postflight (Sprint `7.6`); also destroyed by `prodbox rke2 delete --cascade` (Sprint `4.11`); destroy deletes non-NS/SOA records first so a failed run's A record cannot keep the hosted zone non-empty | MinIO in-cluster |
| `aws-test` (HA-RKE2 EC2) | `prodbox pulumi test-resources` | `prodbox pulumi test-destroy --yes`; auto-destroyed by the test-harness postflight (Sprint `7.6`); also destroyed by `prodbox rke2 delete --cascade` (Sprint `4.11`) | MinIO in-cluster |

Per-run stacks exist only for the lifetime of a suite run that needs them. The harness owns
the full create/destroy lifecycle; operators do not normally invoke the destroy commands by
hand because the harness already does so on every exit path. Pulumi state for these stacks
lives in MinIO inside the rke2 cluster — state lifetime matches resource lifetime (both die
with the cluster).

### Long-lived cross-substrate shared infrastructure (retained by design)

| Resource | Provisioned by | Destroyed by | Pulumi state backend |
|----------|----------------|--------------|----------------------|
| `aws-ses` stack (sending identity, DKIM, MX, receive rule set, S3 capture bucket, SMTP IAM user) | `prodbox pulumi aws-ses-resources` | `prodbox pulumi aws-ses-destroy --yes` — **only on explicit invocation**; never auto-destroyed by the test-harness postflight, never destroyed by `prodbox rke2 delete` (any flag); destroyed transitively by `prodbox nuke` (Sprint `4.13`) | Dedicated AWS S3 bucket per `prodbox-config.dhall` `pulumi_state_backend` block (Sprint `4.10`) |
| Long-lived `pulumi_state_backend` S3 bucket (Sprint `4.10`) | `ensureLongLivedPulumiStateBucket` precondition in `src/Prodbox/Infra/LongLivedPulumiBackend.hs` (idempotent, admin-credentialed) | `prodbox nuke` (Sprint `4.13`) — final pass after all long-lived stacks are gone; never destroyed by `aws teardown` or `rke2 delete` | n/a (the bucket *is* the backend) |
| Operator-owned Route 53 parent zone for the configured public FQDN | Operator-managed in Route 53 (no `prodbox pulumi` flow) | Operator action against Route 53 — outside the harness surface | n/a |
| Public-edge TLS certificate material (Sprints `4.24`/`7.11`/`8.7`) | cert-manager via the ZeroSSL ACME `ClusterIssuer` (`zerossl-dns01`); retained material written to a substrate-scoped key (`public-edge-tls/<substrate>/<fqdn>`) in the long-lived `pulumi_state_backend` S3 bucket and restored before every issuance | `prodbox nuke` only; never destroyed by `aws teardown` or `rke2 delete`; registered as a `LongLived` managed resource (Sprint `4.24`) | Long-lived `pulumi_state_backend` S3 bucket |

Retained by design — not orphaned. SES domain identity + DKIM verification requires 5–30 min
of DNS propagation per provision; only one receive rule set may be active per AWS account; S3
bucket names have a ~24-hour reuse cooldown; and re-ordering the public-edge ZeroSSL certificate
on every rebuild would needlessly consume ZeroSSL issuance quota — the TLS analogue of the SES
cooldown — so the public-edge certificate is issued once and restored from the long-lived S3
store on every rebuild rather than re-ordered. Per-run re-provision is impractical at suite
cadence. The harness explicitly carves these resources out of postflight auto-destroy so
operators can run the suite at a sane cadence without rebuilding shared infrastructure each
time. Pulumi state for the `aws-ses` stack lives in the dedicated long-lived S3 bucket
(Sprint `4.10`) rather than in MinIO, so cluster wipes and rebuilds preserve the ability to
reconcile the stack. If that state bucket is removed while retained fixed-name resources still
exist, `prodbox pulumi aws-ses-resources` repairs the supported state by recreating the backend
stack, importing the retained capture bucket / SMTP IAM user / SES receipt resources, rotating
stale SMTP access keys, and reconciling overwrite-tolerant Route 53 records.

When an operator wants the long-lived resources gone (e.g., decommissioning the project or
account), the supported path is the explicit destroy command in the table above, or the
operator-only `prodbox nuke` for total teardown. There is no "managed-by-someone-else"
category — the harness still owns the create/destroy lifecycle; it simply does not invoke
destroy on its own for this class.

### K8s-controller-created AWS resources (cluster-tagged)

| Resource | Created by | Tag signature | Destroyed by |
|----------|------------|---------------|--------------|
| EBS volumes for PVCs | EBS CSI driver responding to `PersistentVolumeClaim` resources | `kubernetes.io/cluster/<cluster-name>: owned`, `ebs.csi.aws.com/cluster-name: <cluster-name>` | K8s drain phase (Sprint `4.12`); fallback postflight tag sweep |
| ALBs / NLBs / target groups / security groups | AWS Load Balancer Controller responding to `Service type=LoadBalancer` and `Ingress` resources | `kubernetes.io/cluster/<cluster-name>: owned`, `elbv2.k8s.aws/cluster`, `ingress.k8s.aws/stack` | K8s drain phase (Sprint `4.12`); fallback postflight tag sweep |
| Route 53 TXT records (`_acme-challenge.*`) | cert-manager DNS01 solver | Record-name pattern `_acme-challenge.*.<configured public FQDN>` | K8s drain phase (Sprint `4.12`) by deleting `Certificate` resources first; fallback postflight tag sweep |
| Route 53 A records for DNS bootstrap | Direct `aws` CLI subprocess in `src/Prodbox/CLI/Rke2.hs:2484` and `src/Prodbox/TestValidation.hs:1547` | None reliably; identified by content (configured public FQDN) | Best-effort cleanup paths in the same modules; fallback postflight tag sweep |

These resources are **not** Pulumi-tracked. They are created by Kubernetes operators or by
direct AWS API calls from the harness and survive Pulumi-stack destruction unless drained
first. The leak class is owned by the K8s drain phase in Sprint `4.12` plus the postflight
tag sweep that fails any destructive lifecycle command if cluster-tagged resources survive;
see
[../documents/engineering/lifecycle_reconciliation_doctrine.md](../documents/engineering/lifecycle_reconciliation_doctrine.md).

### Orphaned IAM residue (operator-cleaned residual class)

| Resource | Origin | Why it orphans | Cleanup owner |
|----------|--------|----------------|---------------|
| `aws-eks-test-aws-lb-controller` policy/role, `aws-eks-test-ebs-csi-driver` role (fixed-name), and auto-named `clusterRole-*` / `nodeRole-*` | The `aws-eks` Pulumi program (per-run) | A `pulumi up` partially succeeds (IAM created early), then its state is lost — the create-then-crash window, or a `.data/` wipe / cluster crash before the per-run `pulumi destroy` | Operator, via the bounded escape hatch (targeted `aws iam delete-policy` / `delete-role`) |
| Operational `prodbox` IAM user + access key + `prodbox-inline` policy | `prodbox aws setup` / the test-harness IAM bootstrap | An interrupted run leaves it; `rke2 delete` does not own it (`aws teardown` / the harness postflight does) | `prodbox aws teardown`, or operator via `aws iam delete-user` |

This IAM residue is the one leak class with **no automated detection backstop**: the AWS
Resource Groups Tagging API does not return IAM resources, so the postflight tag sweep cannot
see it (see
[lifecycle_reconciliation_doctrine.md § 6a](../documents/engineering/lifecycle_reconciliation_doctrine.md)).
It is handled by **prevention, not auto-cleanup**: Sprint `4.19`'s fail-closed delete gate
stops `rke2 delete` / `aws teardown` from silently reporting "clean" when the per-run Pulumi
state backend is unreachable (the condition that let this residue accumulate undetected),
and pre-existing IAM orphans are removed by operator action. A deliberate decision was made
**not** to add an AWS-name-scanning detector (scanning live AWS behind Pulumi is an
anti-pattern) and **not** to add an auto-sweep (silent cleanup would mask genuine logical
leaks). A live operator cleanup of accumulated IAM orphans (1 policy + 3 roles + the
operational `prodbox` user, dated 2026-04-25 through 2026-05-28) was performed 2026-05-28 —
see [README.md → Closure Status](README.md).

### Operational resources (registered, ephemeral per run)

| Resource | Created by | Discover | Destroyed by |
|----------|------------|----------|--------------|
| Operational `prodbox` IAM user (+ access key + `prodbox-inline` policy) | `prodbox aws setup` / the test-harness IAM bootstrap | `aws iam get-user` | `prodbox aws teardown` (`reconcileAbsent`) |
| Operational `aws.*` block in `prodbox-config.dhall` | `prodbox aws setup` materializing from `aws_admin_for_test_simulation.*` | config-block-non-empty | `prodbox aws teardown` clears it to empty |

These are **registered `Operational`-class resources** in the managed-resource registry
(scheduled in Phase `4` Sprint `4.20` and Phase `7` Sprint `7.8`). Before the registry they
were created by `aws setup` with no registered discover/destroy, which is why an interrupted
run leaked both undetected. The registry gives each a `discover` + `destroy` so `aws teardown`'s
`reconcileAbsent` pass reconciles them like any other resource.

### Lifecycle ownership rule

No new AWS or cluster resource type may be added by any `prodbox` code path without a
corresponding **managed-resource registry** entry (typed `discover` + `destroy`, with a
`LifecycleClass` of `PerRun` / `LongLived` / `Operational`). The registry
(`Prodbox.Lifecycle.ResourceRegistry`, scheduled in Phase `4` Sprint `4.20`) is the
machine-enforced single source of truth: `Prodbox.Aws.perRunStackNames` /
`longLivedStackNames` are **derived from** it, and `prodbox check-code` (Sprint `4.22`)
fails the build if this Resource Lifecycle Classes section drifts from the registry or if
any `aws`/`pulumi` create call site has no registered counterpart. The doctrine SSoT is
[../documents/engineering/lifecycle_reconciliation_doctrine.md § 3.1](../documents/engineering/lifecycle_reconciliation_doctrine.md).
This Resource Lifecycle Classes table becomes a registry-sourced **generated section** when
Sprint `4.22` lands its renderer; until then it is maintained by hand and checked against the
registry by review.

## Cross-Substrate Shared Resources

This table is the **authoritative inventory** of every AWS resource any `prodbox` flow may
create or destroy under the long-lived shared-infrastructure class above. No `prodbox` code
path may add a new AWS resource type without first appearing in this table (or in the
per-run-stacks table above for the auto-managed class). Both substrates depend on the
resources listed here; provisioning and teardown stay per-substrate for the per-run stacks
and one-time/on-demand for the resources below.

| Resource | Owner | Phase ownership | Provisioning surface | Used by |
|----------|-------|-----------------|----------------------|---------|
| Route 53 hosted zone for the configured public FQDN | Operator AWS account | [phase-7-aws-substrate-foundations.md](phase-7-aws-substrate-foundations.md) | Operator-managed in Route 53 (no `prodbox pulumi` flow) | Both substrates (home substrate for the live public record; AWS substrate when its parity sprint adds public-edge proofs) |
| AWS SES sending identity (domain) | Operator AWS account | [phase-8-email-invite-auth.md](phase-8-email-invite-auth.md) | `prodbox pulumi aws-ses-resources` / `aws-ses-destroy` — `pulumi/aws-ses/` | Both substrates running `ValidationKeycloakInvite` |
| AWS SES receive subdomain + MX records + receive rule set + S3 capture bucket | Operator AWS account | [phase-8-email-invite-auth.md](phase-8-email-invite-auth.md) | `prodbox pulumi aws-ses-resources` / `aws-ses-destroy` — `pulumi/aws-ses/` | Both substrates running `ValidationKeycloakInvite` |
| SMTP IAM user + access key for Keycloak SES SMTP | Operator AWS account | [phase-8-email-invite-auth.md](phase-8-email-invite-auth.md) | `prodbox pulumi aws-ses-resources` / `aws-ses-destroy` — `pulumi/aws-ses/` (`ses:SendRawEmail` + capture-bucket read/delete); invite-aware per-cluster sync applies `keycloak-smtp` before Keycloak chart render, and `prodbox users invite` patches existing realms from that Secret before send | Keycloak chart `smtpServer` block (Sprint `8.2`); native validation harness for `ValidationKeycloakInvite` (Sprint `8.5`) |

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
