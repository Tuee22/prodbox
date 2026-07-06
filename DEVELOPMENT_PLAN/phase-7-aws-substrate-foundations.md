# Phase 7: AWS Substrate Foundations

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [00-overview.md](00-overview.md),
[system-components.md](system-components.md),
[substrates.md](substrates.md),
[phase-8-email-invite-auth.md](phase-8-email-invite-auth.md),
[legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md),
[the engineering doctrine docs](../documents/engineering/README.md),
[vault_doctrine.md](../documents/engineering/vault_doctrine.md),
[resource_scaling_doctrine.md](../documents/engineering/resource_scaling_doctrine.md)
**Generated sections**: none

> **Purpose**: Own the AWS substrate's foundations — the interactive onboarding wizard, the
> standalone AWS IAM and quota command surface, the temporary-admin-credential validation harness
> for real IAM lifecycle proof, and (Sprint `7.5`) the AWS-substrate-parity sprint that brings
> the AWS substrate to canonical-suite parity with the home substrate.

## Phase Status

✅ **Reclosed 2026-07-05 for daemon-mediated Pulumi/object-store access.** Sprint `7.30` is now
Done on its code-owned surface. Encrypted Pulumi backend hydration/persistence, per-run residue
checks, stack-output reads, and corrupt-checkpoint prune deletes now use the loopback-restricted
daemon object-store API; the daemon resolves Vault Transit/HMAC material through Kubernetes auth
and reaches MinIO over in-cluster Service DNS. Earlier AWS substrate, IAM, encrypted-backend,
static-EBS, and VPC ownership surfaces remain `Done`/as-tracked on their owned validation axes.
Live AWS/EKS parity remains a non-blocking Standard O proof axis tracked in
[substrates.md](substrates.md).

✅ **Live-proven 2026-06-26 (the AWS per-run resource cycles the home suite exercises) — partial; the
`--substrate aws` aggregate stays open.** The green home `prodbox test all` (2026-06-26, 18/18; see
[00-overview.md](00-overview.md) Alignment Status) provisions **and cleanly destroys** real AWS per-run
resources through Phase 7's owned surface, live-proving these previously `🧪 Live-proof: pending` axes
on real infrastructure: the `aws-eks` stack (a real EKS cluster + NAT/EBS, provisioned then destroyed,
`destroyed and residue check passed`) and `aws-test` stack; the decrypt-to-scratch Pulumi interposition
and first-touch checkpoint hooks (Sprint `7.14`); the read-only per-run-destroy observation gates
(Sprints `7.21`/`7.22`); the `aws-ses` encrypted Model-B reconcile (Sprint `7.23`, exercised by the
`keycloak-invite` SMTP path); the IAM mint→Vault / delete-from-AWS-and-Vault harness (`7.20`, via
`aws-iam`); and Route 53 writes (`dns-aws`). This run also fixed the `plaintext`→`passphrase`
secrets-provider on the three per-run stacks (see [README.md](README.md) Closure Status). Note the run
was a **home-substrate aggregate** that provisions these AWS *stacks* as suite content; the full
**`--substrate aws` aggregate parity** (Sprint `7.5`) remains a distinct, non-blocking live-infra axis
tracked only in [substrates.md](substrates.md) — it is not closed by this home run (Standards N/O).

**Independent Validation**: Phase 7 is validatable on its owned surface — the AWS substrate
foundations, the standalone `prodbox aws ...` command surface, the substrate-provisioning code,
and the decrypt-to-scratch Pulumi interposition — independently of any later phase, per
[development_plan_standards.md → N. Phase Independence](development_plan_standards.md#n-phase-independence-no-backward-blocking).
Code-owned closure is proven locally (`prodbox dev check`, `prodbox test unit`,
`prodbox test integration cli`/`env`) plus live home-substrate reconcile; validations that touch a
later-phase dependency are exercised against the home/local substrate or a fixture. Proof that
needs live AWS spend, an unsealed Vault, or an operator-supplied credential is tracked as a
non-blocking `Live-proof: pending` note per
[development_plan_standards.md → O. Code-Local vs Live-Infra Proof](development_plan_standards.md#o-code-local-completion-vs-live-infra-proof);
it never gates this phase or an earlier one.

✅ **Reclosed after the 2026-06-17 Phase 7 owned-surface expansion** — two new sprints expanded the
AWS/Vault credential + substrate surface this phase owns (narrated in
[README.md → Closure Status](README.md) per rule A). Sprint `7.19` staged Tier 1 — the
password-gated Vault unlock bundle relocated off host disk into the durable MinIO bucket — and was
closed by Sprint `7.25`'s disk-free MinIO unseal cutover. Sprint `7.20` closed the test-harness IAM
credential lifecycle doctrine and teardown-completeness guard on its code-owned surface. Both adopt
the three-tier config model defined
in [config_doctrine.md §0](../documents/engineering/config_doctrine.md) by name rather than
restating it. All earlier Phase 7 sprints (`7.1`–`7.18`) stay `Done` on their owned scope.

✅ **Reclosed 2026-06-23 for the disk-free Vault unseal cutover** — Sprint `7.25`
took the unlock bundle fully into MinIO (host disk holds no unseal material): MinIO becomes
cluster-only (its chart's Vault init container removed, static root cred injected directly), is
reordered ahead of Vault, and the host-disk bundle write + fallback are dropped. This **closes Sprint
`7.19`'s deferred 🧪 disk-free axis**, unblocked by the 2026-06-22 static MinIO credential. See the
Sprint `7.25` block below + [README.md → Closure Status](README.md).

✅ **Reclosed 2026-06-23 for an operator-reported teardown-UX bug** — Sprint `7.26` (✅ Done)
fixes the `cluster delete --cascade` postflight tag sweep falsely flagging the intentionally-retained
long-lived `pulumi_state_backend` bucket (and `aws-ses`) as "manual-cleanup-required" residue; the sweep
now carves out the retained long-lived shared-infra classes and refuses only on genuine
per-run/cluster escapees. See the Sprint `7.26` block below.

✅ **Reclosed 2026-07-03 for unified block storage on the AWS substrate** — Phase 7's own
AWS-substrate storage + networking surface is expanded here (narrated in
[README.md → Closure Status](README.md) per rule A). Sprint `7.28` is ✅ Done on its code-owned
surface: it replaces and removes the dynamic `gp2` EKS storage path (Sprint `7.5.c.i`) with
**pre-created EBS volumes lifted in as static `Retain` PVs** (CSI `volumeHandle`, AZ-pinned),
mirroring the home `manual`/no-provisioner model per
[storage_lifecycle_doctrine.md § 1](../documents/engineering/storage_lifecycle_doctrine.md) and
satisfying the "no dynamic provisioning anywhere" invariant of
[cluster_topology_doctrine.md § 4](../documents/engineering/cluster_topology_doctrine.md). Sprint
`7.29` is ✅ Done on its code-owned surface: it hardens EKS VPC ownership (prodbox owns its own VPC;
the test harness always provisions a fresh test VPC; `prodbox.io/managed-by` tags on the
VPC/IGW/route-table/subnets so an escaped VPC is caught by the postflight tag sweep). The
retain-vs-test-delete EBS lifecycle and its
managed-resource class are owned by Phase 4 (Sprints `4.39`/`4.40`), and the identical-rebinding
validation is Phase 5 suite content (Sprint `5.12`). All earlier Phase 7 sprints (`7.1`–`7.27`)
stay `Done`/as-tracked on their owned scope. The legacy dynamic-`gp2` cleanup is recorded in
[legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md) Completed.

✅ **Sprint `7.14` Done (code-owned surface) 2026-06-16** — Sprint `7.14` has landed the
decrypt-to-scratch Pulumi
interposition over the Sprint `4.30` Model-B object-store. `Prodbox.Pulumi.EncryptedBackend`
hydrates checkpoints into a RAM-backed `file://` backend, strips raw MinIO/S3 backend credentials
and Pulumi passphrases from the Pulumi subprocess environment, and re-envelopes the resulting
checkpoint as `LogicalPulumiStack <stack-id>` through `Prodbox.Minio.EncryptedObject`. The main
per-run stack cycles (`aws-eks`, `aws-eks-subzone`, `aws-test`) and the main `aws-ses`
reconcile/destroy/SMTP-sync paths now run through that wrapper; the production residue/output reads
in `StackOutputs` / `LiveResidue` also consult encrypted checkpoint presence and scratch-backed
`pulumi stack output` instead of raw backend listings. The first-touch migration path now imports
legacy raw MinIO / long-lived S3 checkpoints when the encrypted object is absent and deletes the
legacy stack only after the encrypted store/delete and Pulumi action succeed. Pulumi provider
credentials now resolve through `Prodbox.Infra.AwsProviderCredentials`, which requires the Vault KV
object at `secret/gateway/gateway/aws` and does not fall back to raw config credentials. The root
AWS credential schema now uses a mandatory Vault KV `SecretRef.Vault` reference for the generated
operational `aws.*` (the `aws_admin_for_test_simulation.*` test fixture is not a production-config
section and lives in `test-secrets.dhall` per Sprint `7.16`); setup/config-setup write
generated operational keys to `secret/gateway/gateway/aws`, and teardown clears that Vault object
without writing provider secrets to `prodbox.dhall`. Code-owned closure is proven locally
(full unit 950/950, `test integration cli`/`env` 38/38, docs check/lint 0, `dev check` 0) plus a
live home-substrate reconcile. **Live-proof**: pending — the live AWS first-touch
migration/deletion proof and the both-substrate sealed-Vault opacity proof are tracked as a
non-blocking live-infra note (Standard O); they consume the `aws_admin_for_test_simulation.*`
TestPlaintext fixture that Sprint `7.16` lands in `test-secrets.dhall` (the fixture is never a Vault
object). Raw backend environment is now confined to
`LegacyPulumiBackend` first-touch import/delete; supported Pulumi actions receive provider-only
input before the scratch `file://` rewrite. The
`aws-ses migrate-backend` compatibility command now drives the encrypted wrapper instead of raw
MinIO-to-S3 export/import; its remaining cleanup is deciding whether the alias itself can be
removed after live proof. See
[vault_doctrine.md §9/§10](../documents/engineering/vault_doctrine.md) and
[legacy ledger](legacy-tracking-for-deletion.md).

✅ **Reclosed after the 2026-06-14 Vault-root Phase 7 owned-surface expansion** — the Vault-root finalization
(narrated in
[README.md → Closure Status](README.md) per rule A) makes Vault the sole, finalized
secrets / KMS / PKI root for the AWS substrate. Sprints `7.14` and `7.15` are reframed to own
that finalized end state on Phase 7's own surface: the master-seed HMAC-derivation model is
**retired** (not extended),
`FileSecret` / Secret-mounted plaintext Dhall is **removed** (not bridged), and a sealed Vault
fails every AWS-substrate Pulumi op and TLS issuance **closed**. Sprint `7.14` (✅ Done on its
code-owned surface) owns
Vault-Transit-enveloped Pulumi backend objects and prodbox-created AWS identities as Vault KV
`SecretRef.Vault` references; its decrypt-to-scratch wrapper/read path has landed, first-touch raw
migration is code-owned, and the AWS credential schema migration is landed. Sprint `7.15`
is ✅ Done on its code-owned surface for ACME EAB as a Vault-protected authority; native Vault-PKI
material remains a non-blocking live-proof axis. Both
compose the cross-phase Vault platform and transit
seal surfaces (forward build order, not a validation gate): the `1.35`–`1.37`, `3.17`, `3.18`,
`3.20`, `4.29`, and `4.32` foundations have
landed, including chart-secret Vault auth, Kubernetes-auth config, generated/static seed bootstrap,
the structural sealed-startup proof, transit-seal hierarchy, and federated lifecycle cascade. Honest
status: the Vault-root AWS-substrate implementation is code-Done on its owned surface; its
live-AWS validation is a non-blocking `Live-proof: pending` note (Standard O) that consumes the
`aws_admin_for_test_simulation.*` test-simulation
fixture (a TestPlaintext fixture in `test-secrets.dhall` per Sprint `7.16`, never a Vault
object). All earlier Phase 7 sprints
(`7.1`–`7.13`) stay `Done` on their owned scope. See
[vault_doctrine.md](../documents/engineering/vault_doctrine.md),
[cluster_federation_doctrine.md](../documents/engineering/cluster_federation_doctrine.md), and the
[legacy ledger](legacy-tracking-for-deletion.md).

✅ **Reclosed 2026-06-09** — Phase 7 was reopened for Sprints `7.12`–`7.13` (design-intention review;
narrated in [README.md → Closure Status](README.md) per rule A); both have now landed. Sprint `7.12`
✅ made **substrate equivalence a structural invariant**: one `Prodbox.ContainerImage` Envoy release
value pins the Envoy Gateway chart + control plane + data plane together (killing the EG-`1.4.4` /
Envoy-`1.37` skew, audit C79); `checkSubstrateImagePinning` forbids per-substrate chart-version /
image re-pinning of shared components (the lower-layer MetalLB / ALB-controller pins are exempt); a
shared `[PlatformComponent]` inventory + coverage test asserts both installers cover it (a coverage
test, **not** a unified step DAG); and the stale "no Harbor on EKS" prose was corrected. Sprint
`7.13` ✅ renamed the public-edge ACME issuer to the **DNS-01-honest** `zerossl-dns01` (from its
historical HTTP-01-spelled name) from one SSoT constant across code + charts + ~41 doc/test sites
(the old spelling now appears nowhere in code, charts, docs, tests, or goldens), reattributed
the public-edge shared-route ownership to the `keycloak` chart in the doctrine, and removed the
`PublicEdge.hs` `PRODBOX_AWS_SUBSTRATE_HOSTED_ZONE_ID` env read (now settings-sourced; `PublicEdge.hs`
added to `checkEnvVarConfigReads.scopedPaths`). Validation at reclosure: `check-code` 0, `test unit`
821, `integration cli` 35, `integration env` 35, `lint docs` 0, `docs check` 0; the live
issuer-rename-on-rebuild + AWS-substrate `test all` are operator-driven. All earlier Phase 7 sprints
(`7.1`–`7.11`) stay `Done` on their owned scope.

✅ **Sprint `7.11` Done** — Phase 7 renders one ZeroSSL ACME `ClusterIssuer` (`zerossl-dns01`)
and adds a substrate-scoped long-lived cert retention store; all earlier Phase 7 sprints
(`7.1`–`7.10`) stay `Done` on their owned scope.

✅ **Done on owned surfaces** for the historical foundations work — Sprints `7.1`–`7.4` remain
closed on interactive onboarding, AWS IAM management, quota automation, and the
temporary-admin-credential validation harness. Per
[development_plan_standards.md](development_plan_standards.md) standards rule E, Phase 7 stays
`Done` on its owned legacy scope while Phases `0`–`4` are reopened by Sprint 0.2 to adopt
[the engineering doctrine docs](../documents/engineering/README.md). The interactive onboarding flow and standalone
`prodbox aws ...` surface inherit the Plan / Apply + `--dry-run` discipline (Sprint 1.7), the
`CommandSpec` source-of-truth split (Sprint 1.6), and the capability classes for AWS subsystems
(Sprint 1.12) without scheduling a new Sprint 7.X for those concerns.

✅ **Sprint `7.5` Done (live AWS proof, June 5, 2026)** — the AWS substrate now reaches
canonical-suite parity for the Phase 7-owned substrate and public-edge surfaces. The May 2026
scoping review split Sprint `7.5` into three sub-sprints whose deliverables were sized for
sequential, separately validatable sessions:

- **Sprint `7.5.a`** (✅ Done, May 17, 2026) — `Substrate` ADT
  (`SubstrateHomeLocal | SubstrateAws`), `--substrate {home-local|aws}` CLI surface threaded
  through `prodbox test integration ...` and `prodbox test all`, `NativeSuitePlan` gains a
  `nativeSubstrate` field, `testExecutionPlan` takes a `Substrate` parameter and propagates
  it through `TestRunner` and `TestValidation`, every `--substrate aws` invocation surfaces
  an explicit "not yet implemented at Sprint 7.5.a" remedy for chart-deploy /
  public-edge / WebSocket validations. Code-only landing; the kubeconfig extraction,
  per-substrate Route 53 zone field, and substrate-aware `publicFqdn` are deferred to
  Sprint `7.5.b` per the scoping review. Validated with `prodbox check-code`,
  `prodbox test unit` (296 tests pass).
- **Sprint `7.5.b`** (✅ Done, split into `7.5.b.i` and `7.5.b.ii` per the May 17, 2026
  scoping check-in):
  - **`7.5.b.i`** (✅ Done, May 17, 2026) — code-side substrate foundations: EKS kubeconfig
    extraction (`materializeAwsEksKubeconfig` in `src/Prodbox/Infra/AwsEksTestStack.hs`),
    substrate-aware helpers (`substrateKubeconfigPath`, `substrateHostedZoneId`,
    `substratePublicFqdn` in `src/Prodbox/PublicEdge.hs`), and the `aws_substrate` Dhall
    block (`hosted_zone_id`, `subzone_name`) wired through
    `prodbox-config-types.dhall`, binary-sibling `prodbox.dhall`, and
    `src/Prodbox/Settings.hs::AwsSubstrateSection`. Code-only; validated with
    `prodbox check-code` and `prodbox test unit` (296/296 pass).
  - **`7.5.b.ii`** (✅ Done) — AWS Load Balancer Controller IAM policy + IRSA setup in
    `pulumi/aws-eks/Main.yaml`, subnet tags for ALB discovery, a new Pulumi program for the
    per-substrate Route 53 hosted subzone with NS delegation, cert-manager DNS01
    `ClusterIssuer` rendering substrate-aware in `src/Prodbox/CLI/Rke2.hs`,
    substrate-aware `ChartPlatform.hs` branching that consumes
    `substrateKubeconfigPath`, and AWS LB Controller + Envoy Gateway install paths on the
    EKS substrate. Validated with live AWS apply in Sprint `7.5.c`.
- **Sprint `7.5.b.iii`** (✅ Done, May 18, 2026) — substrate-independence doctrine refactor
  making the no-fallback contract explicit across
  [development_plan_standards.md → M.](development_plan_standards.md#m-test-suite-substrates),
  [substrates.md](substrates.md), and the engineering doc set. Reclassifies the helper
  fallback shipped in 7.5.b.i / 7.5.b.ii.a as scheduled cleanup residue; the code
  reconciliation is owned by Sprint `7.5.c`'s validation-arms-refinement budget. Validated
  with `prodbox check-code`, `prodbox lint docs`, `prodbox docs check`, `prodbox test unit`
  (300/300), and the prescribed grep audits.
- **Sprint `7.5.c`** (✅ Done, June 5, 2026) — code follow-up landed May 18, 2026
  (`substratePublicFqdn` / `substrateHostedZoneId` fail-fast,
  `resolveAwsEksSubzoneStackConfig` pre-provision gate loosened, `isAwsSubstrateConfigured`
  removed, binary-sibling `prodbox.dhall` updated with the operator-supplied
  `aws_substrate.subzone_name`, ledger row moved from Pending to Completed). Sprint
  `7.5.c.v.f` closed the silent-exit defect; the June 5, 2026 live re-run proved
  AWS public-edge DNS ownership now targets the Envoy NLB and that the subzone/EKS/test
  per-run stacks tear down with residue checks passing. The final June 5,
  2026 live run proved the VS Code, API, WebSocket, admin-route, public DNS,
  and destructive lifecycle validations on AWS: `/vscode` returned the expected
  Keycloak OIDC redirect, `/api` returned the expected JSON payload,
  `charts-websocket --substrate aws` exited successfully after its pod restart
  exercise, Harbor/MinIO admin routes reported accepted `HTTPRoute`s and
  attached `SecurityPolicy` resources on `aws.test.resolvefintech.com`, and
  `ValidationLifecycle` destroyed the local cluster while allowing the
  harness-owned per-run Pulumi residue for postflight. The aggregate run then
  uncovered Phase 8 invite-auth bugs: `ValidationKeycloakInvite` was scheduled
  after destructive validations, initially targeted the home public FQDN during
  an AWS run, and then exposed that the Keycloak public auth route lacked the
  `/auth/admin` match used by the operator invite admin API. Those residuals
  are owned by Sprint `8.6`, not by Phase 7.

## Phase Summary

This phase owns AWS substrate foundations:

1. **AWS substrate foundations (historical, ✅ Done)** — interactive config authoring, policy
   generation, IAM user management, service-quota automation, and the test-simulation
   admin-credential harness. The implemented credential boundary is Haskell-owned: there is exactly
   one runtime path by which elevated/admin AWS power enters prodbox — the interactive
   `SecretRef.Prompt`; public onboarding and public AWS administration prompt for one ephemeral
   elevated credential (prompt-use-discard). The test-harness fixture `aws_admin_for_test_simulation.*`
   is a TestPlaintext fixture whose sole purpose is to simulate that prompt non-interactively for
   suite-driven destructive validation plus long-lived stack / `prodbox nuke` flows. Sprint `7.16`
   has moved that fixture out of production config into the test-harness-only
   `test-secrets.dhall` fixture and unifies all admin acquisition on the prompt; the fixture is
   never read by any production binary and is never stored in Vault. The shared suite-level IAM harness keeps the
   aggregate Pulumi-backend proof behind the visible local runbook and closes the supported
   aggregate validation path on Haskell-owned AWS-user and config cleanup. Sprint `7.4` is
   closed on the single-host onboarding and placeholder-domain removal doctrine for
   `test.resolvefintech.com`.

2. **AWS substrate parity with the canonical suite (Sprint `7.5`, ✅ Done, split into
   `7.5.a`/`7.5.b`/`7.5.c`)** — provision the AWS substrate so it stands up the same chart
   set, ingress, certificates, and DNS records that the home substrate provides today, and
   run the substrate-agnostic canonical-suite validations (`charts-vscode`, `charts-api`,
   `charts-websocket`, `public-dns`, `admin-routes`, public-edge readiness) against the AWS
   substrate. The suite content lives in
   [phase-5-canonical-test-suite.md](phase-5-canonical-test-suite.md); this sprint owns only
   the substrate's provisioning side so those validations have something to run against. The
   sub-sprint split is described in the sprint blocks below.

This phase also provides AWS-substrate foundations consumed cross-substrate (see
[substrates.md → Cross-Substrate Shared Resources](substrates.md#cross-substrate-shared-resources)):
the configured Route 53 hosted zone, and (in coordination with
[phase-8-email-invite-auth.md](phase-8-email-invite-auth.md)) the SES sending identity, receive
subdomain, capture bucket, and the IAM policy granting the runner SES send and S3 access.

## Current Baseline In Worktree

- The public onboarding and standalone AWS administration surfaces are Haskell-owned in
  `src/Prodbox/Aws.hs`, `src/Prodbox/CLI/Parser.hs`, and `src/Prodbox/Native.hs`. All Python
  command wrappers and IAM helpers have been removed.
- The settings path is fully Haskell-owned in `src/Prodbox/Settings.hs` for the direct
  `Dhall -> Haskell types` contract through the native `dhall` library, display, and validation
  with no supported JSON materialization path.
- Haskell proof exists in `test/unit/Main.hs`, and the intended built-frontend fake-AWS proof
  lives in `test/integration/CliSuite.hs`. The real IAM lifecycle named proof runs through the
  native validation harness in `src/Prodbox/TestValidation.hs`.
- `src/Prodbox/TestPlan.hs` and `src/Prodbox/EffectInterpreter.hs` now gate `aws-iam` on an
  explicit native IAM harness readiness check before the validation body runs. The retired
  non-test `aws_admin_for_test_simulation.*` recovery path is removed; later Phase 4 work
  reuses the same test-simulation fixture to drive the interactive admin prompt for long-lived
  stack / `prodbox nuke` teardown flows. The fixture lives in `test-secrets.dhall`; the runtime
  path is the interactive `SecretRef.Prompt`, which the harness simulates from that fixture.
- `src/Prodbox/TestPlan.hs` already routes `prodbox test integration aws-iam`, targeted
  `prodbox test integration <name> --substrate aws` validations,
  `prodbox test integration all`, and `prodbox test all` through the same managed IAM harness
  ownership in `src/Prodbox/TestRunner.hs`, while `src/Prodbox/TestValidation.hs` now treats
  the `aws-iam` validation body as an inspection step rather than as the setup/teardown owner.
- The onboarding surface now closes on the one-host public-edge doctrine and no longer carries
  placeholder-domain defaults.
- `src/Prodbox/Aws.hs` now begins the shared managed harness by probing any pre-existing
  operational `aws.*`, deleting any pre-existing dedicated `prodbox` IAM user plus that user's
  keys, using resolvable pre-existing `aws.*` only to discover and delete the IAM user associated
  with those credentials, and clearing operational `aws.*` before fresh provisioning begins.
- `src/Prodbox/TestRunner.hs` now keeps the managed operational `aws.*` credentials alive for the
  duration of `prodbox test integration aws-iam`, targeted
  `prodbox test integration <name> --substrate aws` validations,
  `prodbox test integration all`, and `prodbox test all`, then clears those credentials again
  even when later prerequisites fail.
- The aggregate runner now reuses the canonical repo-backed Pulumi backend during deferred
  cluster-backed prerequisite checks, so the IAM scope stays isolated to AWS-user and config
  cleanup rather than to ambient host Pulumi login state.

## Sprint 7.1: Interactive Configuration Wizard and Policy Generation in Haskell ✅

**Status**: Done
**Implementation**: `src/Prodbox/Aws.hs`, `src/Prodbox/CLI/Parser.hs`, `src/Prodbox/Native.hs`, `test/unit/Main.hs`, `test/integration/CliSuite.hs`
**Docs to update**: `documents/engineering/aws_account_setup_guide.md`, `documents/engineering/acme_provider_guide.md`, `documents/engineering/cli_command_surface.md`

### Objective

Make the Haskell stack own guided configuration authoring and policy generation.

### Deliverables

- `prodbox config setup` is implemented in Haskell.
- `prodbox aws policy [--tier core|full]` is implemented in Haskell.
- The guided flow preserves AWS account, Route 53 zone, ACME provider, and manual PV-root prompts.
- The wizard writes and validates the binary-sibling Tier-0 `prodbox.dhall` without Python helpers.
- The supported public bootstrap path prompts the operator for one temporary admin credential set
  and does not depend on stored `aws_admin_for_test_simulation.*`.

### Validation

1. `prodbox check-code`
2. `prodbox test unit`
3. `prodbox config setup`
4. `prodbox aws policy --tier full`

### Current Validation State

- `src/Prodbox/Aws.hs` now owns the interactive `prodbox config setup` wizard and native
  `prodbox aws policy [--tier ...]` rendering path.
- `test/unit/Main.hs` now proves parser routing for `config setup` plus the native `aws *` command
  family.
- `test/integration/CliSuite.hs` is the intended built-frontend fake-AWS proof surface for
  `config setup` and `aws policy --tier full`.
- `src/Prodbox/Aws.hs` now keeps the public `config setup` flow on prompt-driven temporary
  admin credentials only; stored `aws_admin_for_test_simulation.*` is not read on the
  supported public path.
### Remaining Work

None.

## Sprint 7.2: Standalone IAM Lifecycle and Quota Automation in Haskell ✅

**Status**: Done
**Implementation**: `src/Prodbox/Aws.hs`, `src/Prodbox/CLI/Parser.hs`, `src/Prodbox/Native.hs`, `test/unit/Main.hs`, `test/integration/CliSuite.hs`
**Docs to update**: `documents/engineering/cli_command_surface.md`, `documents/engineering/aws_integration_environment_doctrine.md`

### Objective

Keep the standalone AWS administration command family on the Haskell runtime while preserving the
supported contract.

### Deliverables

- `prodbox aws setup|teardown|check-quotas|request-quotas` are implemented in Haskell.
- AWS CLI subprocess ownership and explicit credential injection remain canonical.
- IAM user lifecycle remains idempotent.
- Quota inspection and request automation preserve the supported quota set.
- Public `prodbox aws ...` commands obtain temporary admin credentials interactively rather than
  from stored `aws_admin_for_test_simulation.*`.

### Validation

1. `prodbox check-code`
2. `prodbox test unit`
3. `prodbox aws setup --tier full`
4. `prodbox aws teardown`
5. `prodbox aws check-quotas`
6. `prodbox aws request-quotas --tier full`

### Current Validation State

- `src/Prodbox/Aws.hs` now owns `prodbox aws setup|teardown|check-quotas|request-quotas` with
  explicit AWS CLI subprocess environments, IAM user lifecycle orchestration, quota inspection,
  quota requests, and Dhall updates.
- `src/Prodbox/CLI/Parser.hs` now routes the full public `prodbox aws ...` surface through
  `RunNative`.
- `test/integration/CliSuite.hs` is the intended built-frontend fake-AWS proof surface for
  setup/teardown and quota flows.
- `test/integration/CliSuite.hs` now proves the public `prodbox aws ...` commands ignore populated
  `aws_admin_for_test_simulation.*` config and use the interactively supplied temporary admin
  credential instead.
### Remaining Work

None.

## Sprint 7.3: Elevated Credential Harness and Real IAM Lifecycle Proof on the Haskell Stack ✅

**Status**: Done
**Implementation**: `src/Prodbox/Settings.hs`, `src/Prodbox/Aws.hs`, `src/Prodbox/Effect.hs`, `src/Prodbox/EffectInterpreter.hs`, `src/Prodbox/Prerequisite.hs`, `src/Prodbox/TestPlan.hs`, `src/Prodbox/TestRunner.hs`, `src/Prodbox/TestValidation.hs`
**Docs to update**: `documents/engineering/aws_admin_credentials.md`, `documents/engineering/aws_integration_environment_doctrine.md`, `documents/engineering/cli_command_surface.md`, `documents/engineering/integration_fixture_doctrine.md`, `documents/engineering/unit_testing_policy.md`

### Objective

Prove the real IAM lifecycle end to end using the Haskell rewrite and the isolated
`aws_admin_for_test_simulation` credential harness, while making the named and aggregate IAM
validation surfaces share one idempotent cleanup path that leaves no dedicated `prodbox` IAM user
or operational `aws.*` credentials behind.

### Deliverables

- `aws_admin_for_test_simulation` remains isolated from the normal operational `aws.*` section.
- `prodbox test integration aws-iam`, targeted
  `prodbox test integration <name> --substrate aws` validations,
  `prodbox test integration all`, and `prodbox test all` share one joint idempotent IAM
  validation harness.
- That shared harness begins by deleting any pre-existing dedicated `prodbox` IAM user and all of
  that user's access keys.
- When pre-existing operational `aws.*` credentials exist in Vault/Tier-0 config, the harness
  uses those credentials only to discover and delete the IAM user associated with them before it
  provisions fresh operational credentials.
- Real IAM setup and teardown validation closes on the Haskell stack without leaving a dedicated
  `prodbox` IAM user or operational `aws.*` credentials behind.
- The `aws_admin_for_test_simulation.*` test-simulation fixture is reserved for suite-driven
  destructive validation plus simulating the admin prompt that long-lived stack / `prodbox nuke`
  flows present. (Sprint `7.16` supersedes the historical placement of this fixture inside
  production config: it is a TestPlaintext fixture that lives only in `test-secrets.dhall`,
  is never read by a production binary, and is never stored in Vault; the runtime admin path is the
  interactive `SecretRef.Prompt`, which the harness simulates from `test-secrets.dhall`.)
- The native IAM validation harness, and the harness-simulated runs of long-lived stack operations
  and `prodbox nuke`, are the consumers of the `aws_admin_for_test_simulation.*` fixture (real
  operator runs of those flows prompt for the ephemeral elevated credential instead).
- The shared harness simulates the interactive public CLI workflow by materializing operational
  `aws.*` only from `aws_admin_for_test_simulation.*` for the duration of the validation run.
- The shared harness clears operational `aws.*` from Vault KV before returning.
- The operator docs for account setup, ACME provider choice, and temporary-admin credential
  handling are aligned with the Haskell implementation.

### Validation

1. `prodbox test unit`
2. `prodbox test integration cli`
3. `prodbox test integration env`
4. `prodbox test integration aws-iam`
5. `prodbox test integration all`
6. `prodbox test all`

### Current Validation State

- The isolated `aws_admin_for_test_simulation` config contract and the Haskell IAM runtime surface
  are implemented in `src/Prodbox/Settings.hs` and `src/Prodbox/Aws.hs`.
- `src/Prodbox/TestPlan.hs`, `src/Prodbox/Prerequisite.hs`, and `src/Prodbox/EffectInterpreter.hs`
  now gate `prodbox test integration aws-iam` on native IAM harness readiness before the
  validation body runs, and `src/Prodbox/TestPlan.hs` plus `src/Prodbox/TestRunner.hs` now route
  the named and aggregate IAM suite surfaces through the same managed suite-level harness.
- `src/Prodbox/Aws.hs` now begins the shared managed harness by deleting any pre-existing
  dedicated `prodbox` IAM user and that user's keys, probing pre-existing operational `aws.*`
  only to discover and delete the IAM user associated with those credentials when STS can still
  resolve it, clearing operational `aws.*`, provisioning fresh operational credentials from
  `aws_admin_for_test_simulation.*`, proving STS-federated operational credentials with a compact
  AWS-validation session policy, and then waiting for the dedicated IAM-user credentials to pass
  STS plus repeated Route 53 hosted-zone probes before materializing them in the repository config
  because cert-manager Route 53 DNS01 credentials do not support an STS session-token field.
- `src/Prodbox/TestValidation.hs` now limits the `aws-iam` validation body to inspecting the
  managed operational IAM identity, while `src/Prodbox/TestRunner.hs` owns harness teardown so
  aggregate AWS-backed validations can continue to use the temporary operational credentials until
  suite completion.
- The retired public-command fallback to `aws_admin_for_test_simulation.*` has been removed; public
  `config setup` and public `aws ...` commands still prompt instead of reading stored admin
  credentials.
- `src/Prodbox/TestPlan.hs`, `src/Prodbox/TestRunner.hs`, and `src/Prodbox/Prerequisite.hs` now
  split the aggregate and cluster-backed suite prerequisite contract into an initial fail-fast
  gate plus a deferred backend proof, so `pulumi_logged_in` no longer runs before the visible
  `rke2 reconcile` phase has created or repaired the supported local MinIO backend.
- `src/Prodbox/EffectInterpreter.hs` now checks bounded `pulumi login ... --non-interactive`
  against the canonical repo-backed MinIO backend during deferred prerequisites, and the shared
  `src/Prodbox/Infra/MinioBackend.hs` helper recreates a deleted MinIO export host path plus
  restarts `statefulset/minio` before retrying that proof, so the aggregate IAM run no longer
  depends on stale ambient Pulumi host-login state or a detached retained-storage mount.
- The aggregate IAM proof is sequenced before downstream AWS-backed suites through the named
  prerequisite DAG rather than through ambient host Pulumi login state.
- The named and aggregate IAM closure gates are implemented on the same native suite path:
  `prodbox test integration aws-iam`, targeted
  `prodbox test integration <name> --substrate aws` validations,
  `prodbox test integration all`, and `prodbox test all`.
  Environment-dependent end-to-end proof remains attached to those commands rather than duplicated
  here as an execution log.
- `src/Prodbox/CLI/Rke2.hs` now retries transient Harbor `502` / `unexpected EOF` failures during
  lifecycle-owned custom-image publication so destructive reruns do not fail terminally on a
  single short-lived Harbor registry write error, and the lifecycle now closes on host-native
  Docker builds rather than any cross-arch `docker buildx` path.

### Remaining Work

None.

## Sprint 7.4: Single-Hostname Onboarding and Placeholder-Domain Removal ✅

**Status**: Done
**Implementation**: `src/Prodbox/Aws.hs`, `src/Prodbox/Settings.hs`, `src/Prodbox/CLI/Parser.hs`, `src/Prodbox/Native.hs`, `test/unit/Main.hs`, `test/integration/CliSuite.hs`, `test/integration/EnvSuite.hs`, `prodbox-config-types.dhall`
**Docs to update**: `documents/engineering/aws_account_setup_guide.md`, `documents/engineering/acme_provider_guide.md`, `documents/engineering/cli_command_surface.md`, `documents/engineering/aws_integration_environment_doctrine.md`

### Objective

Collapse the onboarding and config-validation surface from multiple public FQDN prompts to the one
supported hostname `test.resolvefintech.com`, while removing `example.com` from defaults, wizard
output, fixtures, and validation assumptions.

### Deliverables

- `prodbox config setup` prompts for the single supported public hostname contract rather than
  separate Keycloak, browser, API, and WebSocket FQDNs.
- The wizard, schema, and validators never emit or accept `example.com` placeholder public
  domains on the supported path.
- Config validation fails fast when the canonical hostname does not belong to the selected Route 53
  zone.
- The built-frontend fake-AWS proof surfaces align with the one-host public-edge doctrine.

### Validation

1. `prodbox check-code`
2. `prodbox test unit`
3. `prodbox test integration cli`
4. `prodbox test integration env`
5. `prodbox config setup`
6. `prodbox config validate`

### Current Validation State

- `src/Prodbox/Aws.hs` already owns the interactive wizard and standalone AWS administration
  flows.
- `src/Prodbox/Aws.hs`, `src/Prodbox/Settings.hs`, and `prodbox-config-types.dhall` now close on
  one canonical public hostname, reject placeholder-domain residue, and enforce selected-zone or
  canonical-hostname consistency on the supported onboarding path.

### Remaining Work

None.

## Sprint 7.5: AWS Substrate Parity with the Canonical Suite ✅

**Status**: ✅ Done on the Phase 7-owned AWS substrate surface (`7.5.a` ✅ Done May 17, 2026;
`7.5.b` ✅ Done May 17, 2026; `7.5.b.iii` ✅ Done May 18, 2026; `7.5.c` ✅ Done after the June 5,
2026 live AWS-substrate canonical-suite proof)
**Blocked by**: none — the required AWS substrate foundations (`7.1`–`7.4`) are closed.

This sprint's owned surface is the AWS substrate's provisioning side, validatable now against
its own surface independently of any later phase (Standard N). New canonical-suite prerequisites
introduced by Phase 5 are not a backward block on this phase: AWS-substrate *coverage* of any
suite-content validation is tracked only in
[substrates.md](substrates.md)'s parity table (Standard M / Standard N principle 4), never as a
block that reopens or gates this sprint.

The May 17, 2026 scoping review split this sprint into three sequentially-validatable
sub-sprints. The overall objective and deliverables remain the same; the split exists so each
sub-sprint can be implemented and validated in a focused session without holding a wide
substrate-threading change open while live AWS infrastructure is being designed and
provisioned.

### Objective (sprint-level, unchanged across the split)

Bring the AWS substrate to behavioral parity with the home substrate for the canonical test
suite. After this sprint's three sub-sprints close, every validation that runs on the home
substrate today also runs on the AWS substrate when the AWS substrate is the active substrate
for a suite run, and the substrate parity row in [substrates.md](substrates.md) for AWS
becomes ✅ Full canonical suite.

### Sprint-level Deliverables (allocated to sub-sprints below)

- AWS substrate provisioning (per substrate, per active suite run) stands up:
  - A per-substrate Route 53 hosted zone or subdomain delegation (e.g. `aws.<configured_zone>`
    or a stack-specific subzone) so the substrate has its own public hostname distinct from
    the home substrate's `test.resolvefintech.com`. (`7.5.b`)
  - cert-manager + the real ZeroSSL ACME provider configured against that hosted zone.
    (`7.5.b`)
  - An ingress comparable to the home substrate's MetalLB + Envoy Gateway pairing (EKS native
    NLB + Envoy Gateway, or equivalent — implementation choice belongs to this sprint).
    (`7.5.b`)
  - The supported chart set (`gateway`, `keycloak`, `vscode`, `api`, `websocket`, plus their
    Patroni and Redis dependencies) deployed via `prodbox charts reconcile` against the AWS
    substrate cluster. (`7.5.b`)
  - The same prerequisite set (`infra_ready`, `public_edge_ready`, `k8s_ready`, chart-platform
    prereqs) satisfied for the AWS substrate. (`7.5.b`)
- The canonical-suite content (`charts-vscode`, `charts-api`, `charts-websocket`,
  `public-dns`, `admin-routes`, public-edge readiness, `keycloak-invite`, and later
  suite additions tracked in `src/Prodbox/TestPlan.hs`) runs unchanged against the AWS
  substrate and produces the same pass/fail semantics as on the home substrate. The
  validations themselves do not change; only the substrate they target changes. (`7.5.c`)
- AWS substrate teardown leaves no AWS residue: no orphaned hosted zone, no orphaned cert,
  no leaked ACME order/challenge, no stale `HTTPRoute` or `Certificate` resources, no leaked
  EBS volumes from chart PVCs. (`7.5.c`)
- The substrate parity row in [substrates.md](substrates.md) for the AWS substrate is
  updated from 🔄 to ✅, with the link back to this sprint's closure date. (`7.5.c`)
- The aggregate runner (`prodbox test integration all`, `prodbox test all`) optionally
  iterates the canonical suite over multiple substrates when configured to do so; the
  default substrate remains the home local substrate. (`7.5.a` adds the surface; `7.5.c`
  proves both substrates green.)

## Sprint 7.5.a: Substrate ADT, CLI Surface, and EKS Kubeconfig Extraction ✅

**Status**: Done (May 17, 2026)
**Blocked by**: None (initial sub-sprint of the 7.5 split)
**Implementation**: `src/Prodbox/CLI/Command.hs`, `src/Prodbox/CLI/Spec.hs`,
`src/Prodbox/CLI/Parser.hs`, `src/Prodbox/TestPlan.hs`, `src/Prodbox/TestRunner.hs`,
`src/Prodbox/TestValidation.hs`, `src/Prodbox/Lib/ChartPlatform.hs`,
`src/Prodbox/Infra/AwsEksTestStack.hs`, `src/Prodbox/PublicEdge.hs`,
`src/Prodbox/Settings.hs`, `prodbox-config-types.dhall`
**Docs to update**: `DEVELOPMENT_PLAN/substrates.md`, `DEVELOPMENT_PLAN/README.md`,
`DEVELOPMENT_PLAN/phase-7-aws-substrate-foundations.md`,
`documents/engineering/aws_integration_environment_doctrine.md`

### Objective

Land the substrate-shaped type surface and the EKS kubeconfig extraction so that the
chart-deploy and test-runner code paths take a `Substrate` parameter (with `SubstrateHomeLocal`
as the default), without changing live behavior on the home substrate. This sub-sprint is
code-only and substrate-agnostic in the home path; it does not yet stand up the AWS-substrate
ingress or chart set (`7.5.b`) and does not yet run canonical-suite validations against AWS
(`7.5.c`).

### Deliverables

- `Substrate` ADT (`SubstrateHomeLocal | SubstrateAws`) defined in `src/Prodbox/CLI/Command.hs`
  and exported throughout the test/chart-deploy surface.
- `--substrate {home-local|aws}` CLI flag on `prodbox test integration ...` and the aggregate
  `prodbox test integration all` / `prodbox test all` surfaces, with `home-local` as the
  default. The flag is accepted on every `test integration` leaf; legacy invocations without
  the flag continue to target the home substrate.
- `NativeSuitePlan` gains a `nativeSubstrate :: Substrate` field. `testExecutionPlan` honors the
  substrate parameter for downstream propagation.
- `TestRunner` and `TestValidation` accept and propagate the `Substrate` parameter; the
  validation arms that touch chart-deploy or kubeconfig consult the substrate-aware helpers
  (added below) rather than hardcoded home-substrate state. Where the AWS-substrate behavior
  is not yet implemented, the validation arms surface a clear "AWS substrate path not yet
  implemented — wait for Sprint 7.5.b" remedy rather than silently behaving as if the home
  substrate were the target.
- `src/Prodbox/Lib/ChartPlatform.hs` exposes `substrateKubeconfigPath :: Substrate -> FilePath`
  and `substrateRoute53ZoneId :: ValidatedSettings -> Substrate -> Text`. The home-substrate
  branches reproduce the existing hardcoded paths exactly; the AWS-substrate branches read
  from the new dhall fields added below.
- `src/Prodbox/Infra/AwsEksTestStack.hs` gains a `materializeAwsEksKubeconfig`
  post-provision step that invokes `aws eks update-kubeconfig` against the provisioned
  cluster and writes the result to `.prodbox-state/aws-eks-test/kubeconfig`. The kubeconfig
  path is exposed via `substrateKubeconfigPath`.
- `prodbox-config-types.dhall` (and the matching Tier-0 `prodbox.dhall` parameters) gain an optional
  `aws_substrate : Optional { hosted_zone_id : Text, subzone_name : Text }` block. The field
  is optional today; `7.5.b` will make it required when the AWS substrate is the active
  substrate for a suite run.
- `src/Prodbox/PublicEdge.hs::publicFqdn` takes a `Substrate` parameter and returns the
  per-substrate canonical hostname; the home-substrate branch continues to read
  `demo_fqdn` (preserving today's `test.resolvefintech.com` behavior).
- Test-runner help, manpages, completions, and `documents/cli/commands.md` regenerate cleanly
  with the new flag. `trackingGeneratedPaths` keeps the new artifacts under doctrine.

### Validation

1. `prodbox check-code`
2. `prodbox test unit`
3. `prodbox test integration cli`
4. `prodbox test integration env`
5. `prodbox test all` (home substrate, default) — proves no regression.
6. `prodbox test integration cli` with `--substrate aws` parses correctly and surfaces the
   "AWS substrate path not yet implemented" remedy on validation arms that 7.5.b will
   implement (this is the intended state at 7.5.a close).

### Current Validation State

- `src/Prodbox/Substrate.hs` exports the `Substrate` ADT
  (`SubstrateHomeLocal | SubstrateAws`), the `substrateId` helper, and the
  `parseSubstrate` reader used by the CLI.
- `src/Prodbox/CLI/Command.hs::TestCommand` carries a `testSubstrate :: Substrate` field
  honored by `src/Prodbox/TestRunner.hs::runTests`.
- `src/Prodbox/CLI/Spec.hs` adds `substrateOptionParser` and surfaces
  `--substrate SUBSTRATE` on every `test integration ...` leaf plus `test all`,
  defaulting to `home-local`; the legacy `prodbox test ...` invocations stay green.
- `src/Prodbox/TestPlan.hs::NativeSuitePlan` exposes `nativeSubstrate :: Substrate`;
  `testExecutionPlan :: Substrate -> TestScope -> TestExecutionPlan` and every
  `NativeSuitePlan` construction propagates that substrate.
- `src/Prodbox/TestValidation.hs::runNativeValidation :: Substrate -> FilePath ->
  [(String, String)] -> NativeValidation -> IO ExitCode` routes home-substrate flows
  unchanged and surfaces the explicit
  "Validation `<id>` on substrate `aws` is not yet implemented at Sprint 7.5.a" remedy
  for every chart-deploy / public-edge / WebSocket validation.
- The CLI artifacts (`documents/cli/commands.md`, `test/golden/cli/commands.json`,
  `test/golden/cli/help-all.txt`) regenerate cleanly under
  `trackingGeneratedPaths`; golden tests in the unit suite are re-accepted.
- Validated with `prodbox check-code` (exit 0) and `prodbox test unit` (all 296 tests
  pass) on May 17, 2026.

### Remaining Work

None. EKS kubeconfig extraction (`materializeAwsEksKubeconfig`), the
substrate-aware `substrateKubeconfigPath` / `substrateRoute53ZoneId` helpers on
`Prodbox.Lib.ChartPlatform`, the `aws_substrate` Dhall block in
`prodbox-config-types.dhall`, and the substrate-aware `publicFqdn` derivation in
`Prodbox.PublicEdge` are deferred to Sprint `7.5.b` per the May 17, 2026 scoping
review, where they are paired with the AWS-substrate ingress and cert-manager
DNS01 work they exist to support.

## Sprint 7.5.b: AWS-Native Ingress, cert-manager DNS01, and AWS-Substrate Chart Deploy ✅

**Status**: Done (May 17, 2026 — both sub-sprints `7.5.b.i` and `7.5.b.ii` Done; the
substrate-independence doctrine refactor `7.5.b.iii` was added between `7.5.b` and `7.5.c`
and is also Done. The original May 17 scoping note split the sub-sprint into `7.5.b.i` ✅
and `7.5.b.ii` 📋; `7.5.b.ii` then completed in four sub-sub-sprints `a`/`b`/`c.I+II`/
`d.I+II.α+β+γ+δ`, all Done.)
**Blocked by**: Sprint `7.5.a`

The sub-sprint owns the AWS-substrate equivalent of the home substrate's MetalLB + Envoy
Gateway pairing plus the cert-manager DNS01 ClusterIssuer wired against a per-substrate
Route 53 zone, then deploys the canonical chart set against that cluster so the next sub-sprint
can run the canonical-suite validations against it. The May 17, 2026 scoping review split the
sub-sprint into a code-side foundations sub-sub-sprint (`7.5.b.i`) and the live-AWS-applying
ingress/chart sub-sub-sprint (`7.5.b.ii`) so each lands in its own session.

## Sprint 7.5.b.i: Code-Side Substrate Foundations ✅

**Status**: Done (May 17, 2026)
**Blocked by**: Sprint `7.5.a`
**Implementation**: `src/Prodbox/Infra/AwsEksTestStack.hs`, `src/Prodbox/PublicEdge.hs`,
`src/Prodbox/Settings.hs`, `prodbox-config-types.dhall`, binary-sibling `prodbox.dhall`,
`test/unit/Main.hs`, `test/integration/EnvSuite.hs`, `test/integration/CliSuite.hs`
**Docs to update**: `DEVELOPMENT_PLAN/substrates.md`, `DEVELOPMENT_PLAN/README.md`,
`DEVELOPMENT_PLAN/phase-7-aws-substrate-foundations.md`

### Objective

Land the substrate-aware code foundations that `7.5.b.ii` needs without applying any AWS
infrastructure yet: EKS kubeconfig extraction, substrate-aware path/zone/FQDN helpers, the
`aws_substrate` Dhall block, and the matching Haskell record. Code-only; validates with
`prodbox check-code` and `prodbox test unit`.

### Deliverables

- `src/Prodbox/Infra/AwsEksTestStack.hs` exports `materializeAwsEksKubeconfig :: FilePath ->
  AwsEksTestStackSnapshot -> IO (Either String FilePath)` and the deterministic
  `awsEksTestKubeconfigPath` helper. `ensureAwsEksTestStackResources` invokes
  `materializeAwsEksKubeconfig` after a successful EKS reconcile so the kubeconfig is written
  to `.prodbox-state/aws-eks-test/kubeconfig` for downstream consumers.
- `src/Prodbox/PublicEdge.hs` exports `substrateKubeconfigPath :: FilePath -> Substrate ->
  Maybe FilePath`, `substrateHostedZoneId :: ValidatedSettings -> Substrate -> Text`, and
  `substratePublicFqdn :: ValidatedSettings -> Substrate -> String`. The home-substrate
  branches reproduce today's hardcoded paths exactly; the AWS-substrate branches read the
  required values from the `aws_substrate` Dhall block. The shipped 7.5.b.i helpers currently
  fall back to home-substrate values when the AWS block is empty, which Sprint `7.5.b.iii`
  (the substrate-independence doctrine refactor) reclassifies as a doctrine-violating residue.
  Sprint `7.5.c`'s code follow-up replaces that fallback with a fail-fast error per the
  doctrine recorded in
  [development_plan_standards.md → M. Substrate coverage and independence (no fallback)](development_plan_standards.md#substrate-coverage-and-independence-no-fallback).
- `prodbox-config-types.dhall` adds the `aws_substrate : { hosted_zone_id : Text, subzone_name
  : Text }` block. The schema defaults are empty for type-system reasons, but a populated
  block is required for any `--substrate aws` canonical-suite run.
- `src/Prodbox/Settings.hs` exposes `AwsSubstrateSection`, the matching `aws_substrate`
  `ConfigFile` field, the `isAwsSubstrateConfigured` helper, and surfaces the new fields in
  `renderConfigDhall` plus `renderSettingsDisplay`.
- Test fixtures (`test/unit/Main.hs`, `test/integration/EnvSuite.hs`,
  `test/integration/CliSuite.hs`) updated for the new schema; all 296 unit tests pass.

### Validation

1. `prodbox check-code` — exit 0.
2. `prodbox test unit` — 296/296 tests pass.
3. `prodbox docs check` — exit 0.
4. `prodbox config validate` — succeeds (with the unchanged pre-existing "aws.access_key_id
   must not be empty" diagnostic from the supported operational-credentials-from-harness
   pattern).
5. `prodbox config show` materializes the new `aws_substrate` block through the native `dhall`
   decoder into the `AwsSubstrateSection` value used by the harness.

### Remaining Work

None. The AWS Load Balancer Controller IAM + IRSA, Route 53 subzone Pulumi program,
substrate-aware `ClusterIssuer` rendering, substrate-aware `ChartPlatform.hs` branching, and
AWS LB Controller + Envoy Gateway install paths are owned by Sprint `7.5.b.ii`.

## Sprint 7.5.b.ii: AWS Load Balancer Controller, Route 53 Subzone, and Chart-Deploy Substrate Branching ✅

**Status**: Done (May 17, 2026 — all four sub-sub-sprints landed:
`7.5.b.ii.a` ✅, `7.5.b.ii.b` ✅, `7.5.b.ii.c` ✅ (split into `c.I` ✅ + `c.II` ✅),
`7.5.b.ii.d` ✅ (split into `d.I` ✅ + `d.II.α` ✅ + `d.II.β` ✅ + `d.II.γ` ✅ + `d.II.δ` ✅)).
The May 17, 2026 scoping pass split this sub-sprint into four session-sized sub-sub-sprints
because the combined surface (Pulumi + ClusterIssuer + ChartPlatform substrate threading +
AWS LB Controller + Envoy Gateway install) is too large for one session.

- **`7.5.b.ii.a`** (✅ Done, May 17, 2026) — substrate-aware cert-manager `ClusterIssuer`
  rendering. `src/Prodbox/CLI/Rke2.hs::acmeRuntimeManifest` and `acmeClusterIssuerSpec` now
  take a `Substrate` parameter; the home-substrate path calls them with `SubstrateHomeLocal`
  unchanged, and the AWS-substrate path will call them with `SubstrateAws` to bind the
  per-substrate Route 53 hosted zone (via `substrateHostedZoneId` from
  `Prodbox.PublicEdge`). Validated with `prodbox check-code` (exit 0) and
  `prodbox test unit` (296/296 pass).
- **`7.5.b.ii.b`** (✅ Done, May 17, 2026) — Pulumi extensions in `pulumi/aws-eks/Main.yaml`:
  vendored AWS Load Balancer Controller IAM policy
  (`pulumi/aws-eks/aws-lb-controller-iam-policy.json`, 242-line v2.8.2 canonical policy),
  IRSA OIDC provider for the EKS cluster
  (`aws:iam:OpenIdConnectProvider` against `cluster.identities[0].oidcs[0].issuer`), IAM
  role bound to the standard
  `system:serviceaccount:kube-system:aws-load-balancer-controller` web-identity subject,
  `RolePolicyAttachment`, and subnet tags
  (`kubernetes.io/cluster/${clusterName}: shared`, `kubernetes.io/role/elb: "1"`) on the
  two public subnets. New stack outputs `cluster_oidc_issuer`, `oidc_provider_arn`,
  `aws_lb_controller_policy_arn`, `aws_lb_controller_role_arn`,
  `aws_lb_controller_role_name`. The Haskell-side snapshot capture of those outputs is
  intentionally deferred to `7.5.b.ii.d` where the chart-deploy substrate branching will
  consume them. Validated via `python3 -m json.tool` on the policy file,
  `python3 yaml.safe_load` on `Main.yaml`, a no-op `pulumi preview` confirming the program
  parses past resource synthesis (failing only at the expected AWS credential validation
  with fake creds), `prodbox check-code` (exit 0), `prodbox lint files` (exit 0), and
  `prodbox test unit` (296/296 pass).
- **`7.5.b.ii.c`** (✅ Done, split into `7.5.b.ii.c.I` ✅ done May 17, 2026, and
  `7.5.b.ii.c.II` 📋):
  - **`7.5.b.ii.c.I`** (✅ Done, May 17, 2026) — Pulumi YAML for the per-substrate Route 53
    hosted subzone. New `pulumi/aws-eks-subzone/Pulumi.yaml` plus
    `pulumi/aws-eks-subzone/Main.yaml`: AWS provider with the same env-var mappings as the
    existing AWS-substrate stacks, a `aws:route53:Zone` resource for the subzone
    (parameterized by `subzoneName` config matching `aws_substrate.subzone_name`), and an
    NS delegation `aws:route53:Record` in the operator-owned parent zone
    (parameterized by `parentZoneId` matching `route53.zone_id`). Outputs include
    `subzone_id`, `subzone_name`, `subzone_name_servers`, and `parent_ns_record_fqdn`.
    Validated with `python3 yaml.safe_load` and a no-op `pulumi preview` (program
    synthesizes past resource definition; fails only at the expected AWS credential
    validation), `prodbox check-code` (exit 0), and `prodbox test unit` (296/296).
  - **`7.5.b.ii.c.II`** (✅ Done, May 17, 2026) — Haskell-side stack lifecycle in
    `src/Prodbox/Infra/AwsEksSubzoneStack.hs`
    (`ensureAwsEksSubzoneStackResources`, `destroyAwsEksSubzoneStack`,
    `loadAwsEksSubzoneStackSnapshot`/`saveAwsEksSubzoneStackSnapshot`/`clearAwsEksSubzoneStackSnapshot`,
    `assertNoAwsEksSubzoneStackResidue`, `renderAwsEksSubzoneStackReport`) mirroring
    the `AwsEksTestStack` pattern. Reuses `loadOperationalAwsCredentials`,
    `pulumiAwsProviderEnv`, `pulumiBackendBaseEnv`, and `settingsAwsEnv` (newly exported
    from `AwsEksTestStack`) and the existing `MinioBackend` port-forward helpers; the
    subzone-specific pulumi flow helpers are parameterized to `awsEksSubzoneStackName`.
    `resolveAwsEksSubzoneStackConfig` reads `route53.zone_id` and
    `aws_substrate.subzone_name` from settings and projects them to Pulumi config
    (`parentZoneId`, `subzoneName`); fails fast when either is empty.
    `assertNoAwsEksSubzoneStackResidue` queries
    `aws route53 list-hosted-zones-by-name` for orphan subzones and
    `aws route53 list-resource-record-sets` for orphan NS records in the parent zone.
    CLI surface: `prodbox aws stack aws-subzone reconcile` and
    `prodbox aws stack aws-subzone destroy` (with `--yes`/`--dry-run`/`--plan-file`)
    registered through `PulumiAwsSubzoneResources` / `PulumiAwsSubzoneDestroy`
    variants on `PulumiCommand`. Validated with `prodbox check-code` (exit 0),
    `prodbox docs generate` regeneration, and `prodbox test unit` (300/300 pass; up
    from 296 because the two new pulumi subcommands each add a happy-case + an
    unhappy-case parser test).
- **`7.5.b.ii.d`** (✅ Done, split into `7.5.b.ii.d.I` ✅ done May 17, 2026 and
  `7.5.b.ii.d.II` 📋):
  - **`7.5.b.ii.d.I`** (✅ Done, May 17, 2026) — `prodbox charts reconcile` and
    `prodbox charts delete` now accept `--substrate {home-local|aws}` (default
    `home-local`). `ChartsDeploy` and `ChartsDelete` carry the `Substrate`. A new
    `withSubstrateEnvironment` helper in `src/Prodbox/CLI/Charts.hs` brackets the
    chart-deploy / delete action with `setEnv`/`unsetEnv` of `KUBECONFIG` pointed at
    the substrate-specific path (`Nothing` for home so the operator's default
    kubeconfig stays in scope; `.prodbox-state/aws-eks-test/kubeconfig` for AWS).
    Existing helm/kubectl subprocesses in `Prodbox.Lib.ChartPlatform` inherit the
    parent environment, so they automatically target the AWS-substrate cluster when
    the operator selects `--substrate aws`. Validated with `prodbox check-code`
    (exit 0), `prodbox docs generate` regeneration, and `prodbox test unit`
    (300/300 pass).
  - **`7.5.b.ii.d.II`** (✅ Done; the May 17, 2026 scoping pass split this into
    four session-sized sub-sub-sub-sprints `α`/`β`/`γ`/`δ` because of the depth
    that emerged once the Harbor-mirrored image references in the home-substrate
    chart-platform install became visible — the AWS substrate needs an entirely
    parallel install path keyed off upstream registries):
    - **`α`** (✅ Done, May 17, 2026) — EKS snapshot extended to capture the new
      Pulumi outputs added in `7.5.b.ii.b`
      (`cluster_oidc_issuer`, `oidc_provider_arn`, `aws_lb_controller_policy_arn`,
      `aws_lb_controller_role_arn`, `aws_lb_controller_role_name`), with
      backwards-compatible loading of older snapshots (missing fields default to
      empty strings; the AWS LB Controller install fails fast at runtime when the
      role ARN is empty). New `Prodbox.Lib.AwsSubstratePlatform` module exports
      `ensureAwsLoadBalancerControllerRuntime :: FilePath ->
      AwsEksTestStackSnapshot -> IO ExitCode`: applies an IRSA-annotated
      `ServiceAccount` manifest into `kube-system`, adds the `eks` Helm repo
      (`https://aws.github.io/eks-charts`), helm-installs the upstream
      `aws-load-balancer-controller` chart pinned to `1.8.4` with
      `serviceAccount.create=false`, and waits for the controller deployment to
      become ready. The function is exposed but not yet wired into
      `prodbox charts reconcile --substrate aws`; the wiring lands in `β` once the
      Envoy Gateway install path is in place. Validated with `prodbox check-code`
      (exit 0), `prodbox lint haskell` (clean after one
      `Use isAsciiUpper` hlint fix), and `prodbox test unit` (300/300).
    - **`β`** (✅ Done, May 17, 2026) — Envoy Gateway install on EKS via the
      substrate-aware reconcile path.
      `Prodbox.Lib.AwsSubstratePlatform::ensureAwsSubstrateEnvoyGatewayRuntime`
      helm-installs the upstream OCI chart `oci://docker.io/envoyproxy/gateway-helm`
      pinned to `v1.4.4` into the `envoy-gateway-system` namespace, then waits
      for the `envoy-gateway` deployment to become ready. Exposed but not yet
      wired into chart-deploy (wiring lands in `δ`). Validated with
      `prodbox check-code` (exit 0) and `prodbox test unit` (300/300).
    - **`γ`** (✅ Done, May 17, 2026) — cert-manager install on EKS pulling
      from upstream Quay/DockerHub (not Harbor).
      `Prodbox.Lib.AwsSubstratePlatform::ensureAwsSubstrateCertManagerRuntime`
      adds the `jetstack` Helm repo (`https://charts.jetstack.io`),
      helm-installs the upstream `cert-manager` chart pinned to `v1.16.2` (kept
      aligned with the home substrate's version constant in
      `Prodbox.CLI.Rke2`) into the `cert-manager` namespace with
      `crds.enabled=true`, then waits for the cert-manager controller,
      webhook, and cainjector deployments to become ready. The ACME
      `ClusterIssuer` rendering is already substrate-aware as of
      `7.5.b.ii.a` (rendered via `acmeClusterIssuerSpec SubstrateAws`
      against `aws_substrate.hosted_zone_id`); applying that ClusterIssuer
      is part of the orchestrator wired in `δ`. Validated with
      `prodbox check-code` (exit 0) and `prodbox test unit` (300/300).
    - **`δ`** (✅ Done, May 17, 2026) — top-level orchestrator + chart-deploy
      wiring + validation remedy removal.
      `Prodbox.CLI.Rke2` now exports `acmeRuntimeManifest` and
      `acmeClusterIssuerSpec` so the AWS-substrate path can render the
      substrate-aware ACME `ClusterIssuer` without duplicating the logic.
      `Prodbox.Lib.AwsSubstratePlatform::ensureAwsSubstrateAcmeRuntime` writes
      the manifest to a temp file, `kubectl apply -f`s it, and
      `kubectl wait --for=condition=Ready clusterissuer/zerossl-dns01`s.
      `Prodbox.Lib.AwsSubstratePlatform::ensureAwsSubstratePlatformRuntime`
      sequences `α`+`β`+`γ`+ACME after loading the EKS snapshot, failing fast
      when `prodbox aws stack eks reconcile` has not yet been run. The
      orchestrator is wired into `prodbox charts reconcile <chart> --substrate
      aws` via a new `ensurePlatformForSubstrate` helper in
      `Prodbox.CLI.Charts` (no-op for home; orchestrator for AWS). The
      `substrateNotYetImplementedRemedy` wildcard in
      `Prodbox.TestValidation.runNativeValidation` is removed; validations now
      always route to the substrate-agnostic body, wrapped with a new
      `withSubstrateKubeconfigEnv` helper that brackets the action with
      `setEnv`/`unsetEnv` of `KUBECONFIG` (no-op for home; EKS kubeconfig path
      for AWS). Validated with `prodbox check-code` (exit 0),
      `prodbox lint haskell` (clean), and `prodbox test unit` (300/300).

**Blocked by**: Sprint `7.5.b.i`
**Implementation**: `pulumi/aws-eks/Main.yaml`, `pulumi/aws-eks-subzone/` (new) or extension
of `aws-eks/`, `src/Prodbox/Infra/AwsEksTestStack.hs`, `src/Prodbox/Lib/ChartPlatform.hs`,
`src/Prodbox/CLI/Rke2.hs` (ClusterIssuer rendering), `charts/`,
`documents/engineering/envoy_gateway_edge_doctrine.md`,
`documents/engineering/aws_integration_environment_doctrine.md`
**Docs to update**: `DEVELOPMENT_PLAN/substrates.md`, `DEVELOPMENT_PLAN/README.md`,
`DEVELOPMENT_PLAN/phase-7-aws-substrate-foundations.md`

### Objective

Stand up the AWS-substrate equivalent of the home substrate's MetalLB + Envoy Gateway pairing
plus the cert-manager DNS01 ClusterIssuer wired against a per-substrate Route 53 zone, then
deploy the canonical chart set against that cluster so the next sub-sprint can run the
canonical-suite validations against it.

### Deliverables

- AWS Load Balancer Controller installed on the EKS substrate via IRSA-bound IAM service
  account, with the supporting VPC subnet tags and IAM policy provisioned by
  `pulumi/aws-eks/Main.yaml`.
- A per-substrate Route 53 hosted subzone (`aws.<configured_zone>`) with NS delegation from
  the configured parent zone.
- cert-manager `ClusterIssuer` rendered against the per-substrate hosted zone (DNS01 challenge,
  Route 53 provider scoped to the subzone) so real ZeroSSL certificates issue against
  the AWS-substrate FQDN.
- Envoy Gateway plus the supported chart set (`gateway`, `keycloak`, `vscode`, `api`,
  `websocket`, plus their dependencies) deployable through `prodbox charts reconcile <chart>
  --substrate aws` against the AWS-substrate cluster.
- All AWS-substrate-aware code paths added in 7.5.a/7.5.b.i have their behavior implemented
  (no more "AWS substrate path not yet implemented" remedies on chart-deploy or ingress
  paths).

### Validation

1. `prodbox check-code`
2. `prodbox test unit`
3. `prodbox aws stack eks reconcile`
4. `prodbox test integration aws-eks` (existing) — confirms substrate provisioning still
   stable.
5. `prodbox charts reconcile gateway --substrate aws` (and the rest of the chart set) succeed
   against the AWS substrate.
6. cert-manager issues real ZeroSSL certificates against the per-substrate hosted zone.

### Current Validation State (7.5.b.ii.a)

- `src/Prodbox/CLI/Rke2.hs` imports `substrateHostedZoneId` from `Prodbox.PublicEdge` and
  `Substrate (..)` from `Prodbox.Substrate`. `ensureAcmeRuntime` calls
  `acmeRuntimeManifest SubstrateHomeLocal settings prodboxId labelValue`, preserving
  current home-substrate behavior exactly.
- `acmeRuntimeManifest :: Substrate -> ValidatedSettings -> String -> String -> [Value]`
  and `acmeClusterIssuerSpec :: Substrate -> ValidatedSettings -> Value` now route the
  `hostedZoneID` field of the DNS01 solver through `substrateHostedZoneId`. For the home
  substrate this resolves to `route53.zone_id`; for the AWS substrate it resolves to
  `aws_substrate.hosted_zone_id`. The shipped 7.5.b.ii.a code path inherits the same
  home-fallback behavior described under Sprint 7.5.b.i; Sprint `7.5.b.iii` reclassifies that
  fallback as doctrine-violating residue, and Sprint `7.5.c`'s code follow-up replaces it
  with a fail-fast error so an AWS-substrate ACME `ClusterIssuer` fails to materialize when
  `aws_substrate.hosted_zone_id` is empty.
- Validated with `prodbox check-code` (exit 0), `prodbox test unit` (296/296), and
  `prodbox docs check` (exit 0).

### Remaining Work (7.5.b.ii.b/c/d)

`7.5.b.ii.b` (Pulumi AWS LB Controller IAM + IRSA + subnet tags), `7.5.b.ii.c` (per-substrate
Route 53 subzone Pulumi), and `7.5.b.ii.d` (chart-deploy substrate branching + AWS LB
Controller + Envoy Gateway install paths) are `Planned`. Each requires its own focused
session.

## Sprint 7.5.b.iii: Substrate Independence Doctrine ✅

**Status**: Done
**Blocked by**: N/A (closed)
**Implementation**: `DEVELOPMENT_PLAN/development_plan_standards.md`,
`DEVELOPMENT_PLAN/substrates.md`, `DEVELOPMENT_PLAN/phase-7-aws-substrate-foundations.md`,
`DEVELOPMENT_PLAN/phase-5-canonical-test-suite.md`, `DEVELOPMENT_PLAN/00-overview.md`,
`DEVELOPMENT_PLAN/README.md`, `DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md`,
`README.md`, `documents/engineering/unit_testing_policy.md`,
`documents/engineering/aws_integration_environment_doctrine.md`,
`documents/engineering/cli_command_surface.md`,
`documents/engineering/prerequisite_doctrine.md`,
`documents/engineering/integration_fixture_doctrine.md`
**Docs to update**: same as Implementation (this sprint is doc-only doctrine refactor)

### Objective

The 7.5.b.i and 7.5.b.ii.a deliverables shipped substrate-aware helpers
(`substratePublicFqdn`, `substrateHostedZoneId`) and the ACME `ClusterIssuer` substrate
parameter with documented fallback-to-home behavior when the operator's `aws_substrate`
Dhall block is empty. That fallback violates the substrate split's reason for existing —
the home substrate and the AWS substrate must run separate, real, independently configured
canonical-suite proofs, and silently substituting home values for missing AWS config would
let an AWS-substrate run collide with the home substrate's Route 53 zone and FQDN.

This sprint refactors the governed docs to make the no-fallback contract explicit and
reclassifies the existing helper fallbacks as scheduled cleanup residue. Sprint `7.5.c`'s
existing "validation arms refinement" budget owns the code follow-up that brings the
helpers and the `resolveAwsEksSubzoneStackConfig` pre-provision gate into agreement with
this doctrine.

### Deliverables

- New `Substrate coverage and independence (no fallback)` subsection in
  [development_plan_standards.md → M. Test Suite Substrates](development_plan_standards.md#m-test-suite-substrates)
  recording the authoritative doctrine: the canonical suite is composed of per-substrate
  runs against both supported substrates, each run is substrate-locked, and missing
  per-substrate config fails fast with an explicit error.
- New `Substrate Independence (No Fallback)` section in
  [substrates.md](substrates.md) mirroring the doctrine; per-substrate `Required Config`
  rows in the home and AWS inventory tables naming the operator-supplied fields each
  substrate consumes.
- This phase doc reworded so the `Current Validation State` sections for Sprints
  `7.5.b.i` and `7.5.b.ii.a` describe the shipped helper behavior as fallback residue
  superseded by the doctrine, and Sprint `7.5.c` gains explicit `Operator Workflow` and
  `Code follow-up` subsections.
- Cross-references threaded through
  [phase-5-canonical-test-suite.md](phase-5-canonical-test-suite.md),
  [00-overview.md](00-overview.md), [README.md](README.md), and the root
  [../README.md](../README.md).
- New entry in [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md)
  recording the deprecation of the helper fallback semantics; the entry is scheduled for
  closure under Sprint `7.5.c` per
  [development_plan_standards.md → L. CLI Doctrine Alignment](development_plan_standards.md#l-cli-doctrine-alignment).
- Engineering docs (`unit_testing_policy.md`, `aws_integration_environment_doctrine.md`,
  `cli_command_surface.md`, `prerequisite_doctrine.md`,
  `integration_fixture_doctrine.md`) updated with substrate-independence notes that link
  back to the doctrine.

### Validation

1. `prodbox check-code` (exit 0).
2. `prodbox lint docs` (exit 0).
3. `prodbox docs check` (exit 0).
4. `prodbox test unit` (regression check, all green).
5. Manual grep audits across `README.md`, `DEVELOPMENT_PLAN/`, and `documents/`:
   - `grep -nrE "graceful fallback|falling back to home|fallback to .route53|when the (aws |AWS )?block is empty"` returns zero hits in supported-path docs.
   - `grep -nrE "\\b(target|environment|tier)\\b.*(substrate|prodbox)"` returns zero false positives misusing those words as substrate synonyms.
   - `grep -nrE "fallback"` returns only legitimate Docker-registry mirror fallback references.

### Current Validation State

- `DEVELOPMENT_PLAN/development_plan_standards.md` § M now carries the
  `Substrate coverage and independence (no fallback)` subsection making the no-fallback
  contract explicit.
- `DEVELOPMENT_PLAN/substrates.md` carries the `Substrate Independence (No Fallback)`
  section plus per-substrate `Required Config` rows for home local and AWS.
- This phase doc's `Current Validation State` for Sprints `7.5.b.i` and `7.5.b.ii.a`
  describes the shipped helper fallback as doctrine-violating residue; Sprint `7.5.c`
  has explicit `Operator Workflow` and `Code Follow-Up` subsections.
- `DEVELOPMENT_PLAN/phase-5-canonical-test-suite.md`, `00-overview.md`, the development-plan
  `README.md`, and the root `README.md` cross-reference the substrate-independence doctrine.
- Engineering docs (`unit_testing_policy.md`, `aws_integration_environment_doctrine.md`,
  `cli_command_surface.md`, `prerequisite_doctrine.md`, `integration_fixture_doctrine.md`)
  carry the substrate-independence cross-reference.
- `legacy-tracking-for-deletion.md` records the helper-fallback residue scheduled for
  closure under Sprint `7.5.c`'s code follow-up.
- Validated with `prodbox check-code` (exit 0), `prodbox lint docs` (exit 0),
  `prodbox docs check` (exit 0), `prodbox test unit` (300/300), and the three grep audits
  defined under `Validation` (residue-narrative and registry-mirror references only).

### Remaining Work

None. Code reconciliation is owned by Sprint `7.5.c`.

## Sprint 7.5.c: Live AWS-Substrate Canonical-Suite Validation ✅

**Status**: ✅ Done on the Phase 7-owned AWS substrate surface. Sub-sprints `7.5.c.i`,
`7.5.c.ii`, `7.5.c.iii`, `7.5.c.iv`, and `7.5.c.v.b` all landed on their code-owned surfaces by
May 19, 2026; child Sprint `7.5.c.v` closed the operator-driven live AWS-substrate proof on June 5,
2026. Later invite-auth aggregate failures are Phase 8 suite-content work, not Phase 7 substrate
work.
**Independent Validation**: The Phase 7-owned substrate-provisioning surface is validatable on its
own surface now (`prodbox check-code`, `prodbox test unit`, the substrate-platform install unit
ordering tests); the remaining proof needs live AWS spend and is a `Live-proof: pending` note
(Standard O), not a block.
**Implementation**: `src/Prodbox/TestValidation.hs`, `src/Prodbox/Infra/AwsEksTestStack.hs`,
`src/Prodbox/Infra/AwsTestStack.hs`, `src/Prodbox/Lib/AwsSubstratePlatform.hs`,
`src/Prodbox/CLI/Charts.hs`, `src/Prodbox/PublicEdge.hs`,
`src/Prodbox/Infra/AwsEksSubzoneStack.hs`
**Docs to update**: `DEVELOPMENT_PLAN/substrates.md`, `DEVELOPMENT_PLAN/README.md`,
`DEVELOPMENT_PLAN/phase-7-aws-substrate-foundations.md`,
`documents/engineering/unit_testing_policy.md`,
`documents/engineering/aws_admin_credentials.md`,
`documents/engineering/aws_integration_environment_doctrine.md`

### Objective

Run the canonical-suite validations against the AWS substrate end to end, confirm zero
post-teardown residue, and flip the substrate parity rows in
[substrates.md](substrates.md) and [README.md](README.md).

### Deliverables

- `prodbox test integration charts-vscode --substrate aws`,
  `prodbox test integration charts-api --substrate aws`,
  `prodbox test integration charts-websocket --substrate aws`,
  `prodbox test integration public-dns --substrate aws`, and
  `prodbox test integration admin-routes --substrate aws` all pass.
- `prodbox test integration aws-eks` plus `prodbox test integration ha-rke2-aws` continue
  to pass.
- Post-teardown AWS account scan returns zero residue (no orphaned hosted zone records,
  no orphaned certs, no leaked ACME challenges, no stale `HTTPRoute` / `Certificate`
  resources, no leaked EBS volumes).
- The aggregate runner (`prodbox test all`) succeeds against both substrates when run with
  the AWS substrate selection.
- The substrate parity row in [substrates.md](substrates.md) flips from 🔄 to ✅.
- `DEVELOPMENT_PLAN/README.md` Phase Overview row for Phase 7 flips to ✅ Done.

### Validation

1. `prodbox check-code`
2. `prodbox test unit`
3. `prodbox aws stack eks reconcile`
4. `prodbox test integration aws-eks`
5. `prodbox test integration ha-rke2-aws`
6. `prodbox test integration charts-vscode --substrate aws`
7. `prodbox test integration charts-api --substrate aws`
8. `prodbox test integration charts-websocket --substrate aws`
9. `prodbox test integration public-dns --substrate aws`
10. `prodbox test integration admin-routes --substrate aws`
11. AWS post-teardown residue scan returns zero.
12. `prodbox test all` (home substrate, default) still green.

### Sprint Workflow

Per
[development_plan_standards.md → M. Substrate coverage and independence (no fallback)](development_plan_standards.md#substrate-coverage-and-independence-no-fallback),
an AWS-substrate canonical-suite run is locked to AWS-substrate config; nothing falls back
to the home substrate. The harness owns every AWS resource the workflow touches (see
[substrates.md → Resource Lifecycle Classes](substrates.md#resource-lifecycle-classes));
the operator's role is to satisfy the two prerequisite contracts below, set the two config
fields that select the AWS-substrate FQDN, and invoke the entrypoints listed afterward.

The two prerequisite contracts (Steps `0` and `0.5`) are not optional. `prodbox cluster
reconcile`, `prodbox aws stack <stack> reconcile`, and `prodbox aws stack <stack> destroy --yes`
all fail fast when `prodbox.aws.*` operational credentials are empty, and `prodbox aws stack
<stack> reconcile` additionally requires the home substrate's in-cluster MinIO running
because that is the Pulumi state backend. The standalone Sprint `7.5.c.v` workflow is
not driven by `prodbox test all`, so the Sprint `7.6` auto-managed setup + teardown
contract does not apply; the operator owns Steps `0`, `0.5`, and the symmetric closing
teardown step explicitly.

0. **AWS admin credentials populated.** The generated operational `prodbox.aws.*`
   credential must be minted into Vault KV (`secret/gateway/gateway/aws`) before any
   other step; `prodbox.dhall` carries only a `SecretRef.Vault` reference to it,
   never the plaintext key. Because the credential is minted into Vault, this step runs
   after Vault is set up and unsealed. Two supported population paths exist:
   - **Public path** (recommended for this standalone workflow):
     `prodbox aws setup`. Interactive — prompts (via `SecretRef.Prompt`) for one
     ephemeral elevated admin credential pasted from the AWS console, derives the
     dedicated least-privilege `prodbox` IAM identity via STS-federated session, and
     mints the generated operational `aws.*` straight into Vault KV (Sprint `7.16`).
     The prompted elevated credential is held in memory for the one command and
     discarded — never written to `prodbox.dhall`, never stored in Vault.
   - **Harness-simulated prompt path** (reserved for runs driven by
     `prodbox test integration aws-iam`, `prodbox test all`, or later long-lived teardown /
     `prodbox nuke` flows): the `aws_admin_for_test_simulation.*` TestPlaintext fixture in
     `test-secrets.dhall` (a test-harness-only file, never imported by `prodbox.dhall`,
     never stored in Vault) is consumed non-interactively by `runAwsIamHarnessSetup` to simulate
     the operator typing the ephemeral elevated credential at the interactive `SecretRef.Prompt`.
     The same provision-derive contract runs; the generated operational `aws.*` is minted into
     Vault KV (Sprint `7.16`).

   Per Sprint `7.3`, both paths clear `aws.*` on teardown. Because the standalone
   Sprint `7.5.c.v` workflow is not wrapped by the `prodbox test all` setup/teardown
   pair, the operator runs `prodbox aws setup` exactly once at Step `0` and runs the
   symmetric `prodbox aws teardown` exactly once at the closing teardown step
   (described after Step `6`). The operational `aws.*` must survive across Steps
   `0.5` through `6`.

   See
   [`documents/engineering/aws_account_setup_guide.md`](../documents/engineering/aws_account_setup_guide.md),
   [`documents/engineering/aws_admin_credentials.md`](../documents/engineering/aws_admin_credentials.md),
   and
   [`documents/engineering/aws_integration_environment_doctrine.md`](../documents/engineering/aws_integration_environment_doctrine.md)
   for the canonical AWS credentials doctrine.

0.5. **Home substrate reconciled.** `prodbox aws stack <stack> reconcile` invocations
     project the home substrate's in-cluster MinIO as their Pulumi state backend via
     `withMinioPortForward` in `src/Prodbox/Infra/AwsEksTestStack.hs`. Operator runs
     `prodbox cluster reconcile` once before the first `prodbox aws stack` call in this
     workflow. The command is idempotent — a second invocation is a no-op when the
     home substrate is already up. See
     [`../CLAUDE.md`](../CLAUDE.md) § Local Cluster Lifecycle Ownership,
     [`phase-4-lifecycle-canonical-paths.md`](phase-4-lifecycle-canonical-paths.md), and
     [`documents/engineering/aws_integration_environment_doctrine.md` § 4.5 Pulumi State Backend Prerequisite](../documents/engineering/aws_integration_environment_doctrine.md).
1. Operator sets `prodbox.dhall::aws_substrate.subzone_name` to the chosen
   AWS-substrate public FQDN (e.g. `aws.test.resolvefintech.com`). This is a manual
   config edit, not a harness invocation.
2. `prodbox aws stack eks reconcile` provisions the EKS cluster, IRSA, and subnet tags
   (auto-managed per-run stack).
3. `prodbox aws stack aws-subzone reconcile` provisions the per-substrate Route 53
   subzone and NS delegation in the parent zone (auto-managed per-run stack). In
   harness-driven runs, `TestRunner` reads the live `aws-eks-subzone` Pulumi output
   immediately after provisioning and passes the hosted-zone ID to downstream child
   commands via `PRODBOX_AWS_SUBSTRATE_HOSTED_ZONE_ID`; operators may still pin
   `aws_substrate.hosted_zone_id` in config for standalone diagnostics, but the
   canonical harness path does not require a manual edit between provision and
   validation.
4. `prodbox test integration {charts-vscode,charts-api,charts-websocket,public-dns,admin-routes}
   --substrate aws` runs the five AWS-substrate canonical-suite validations.
5. `prodbox aws stack aws-subzone destroy --yes` and `prodbox aws stack eks destroy --yes`
   tear down the per-run stacks (plus `prodbox aws stack test destroy --yes` if the
   HA-RKE2 EC2 stack was provisioned). Per Sprint `7.6`, the harness postflight does
   this automatically on `prodbox test all` exit; manual invocation is for partial
   workflows. Cross-substrate shared SES infrastructure is **not** destroyed here —
   see [substrates.md → Resource Lifecycle Classes](substrates.md#resource-lifecycle-classes).

**Closing teardown — symmetric with Step `0`**: after Step `6` returns, operator runs
`prodbox aws teardown` to delete the dedicated `prodbox` IAM user and clear `aws.*`
from Vault KV. This closes the operational-credential lifecycle the
operator opened at Step `0`. Sprint `7.6`'s `awsPostflightDestroyActions` +
`runManagedAwsHarnessTeardown` pair covers this automatically for runs driven by
`prodbox test all`, but the standalone Sprint `7.5.c.v` workflow does not invoke that
pair, so the operator owns the closing teardown explicitly.

### Code Follow-Up

Sprint `7.5.c`'s validation arms refinement budget owns the code reconciliation between
the substrate-independence doctrine (Sprint `7.5.b.iii`) and the shipped helper /
lifecycle gate behavior:

- `src/Prodbox/PublicEdge.hs::substratePublicFqdn` and `substrateHostedZoneId` replace
  their home-substrate fallback branches with a fail-fast `error` (or `Either`-returning
  variant called from validated entrypoints) so AWS-substrate runs cannot silently use
  home values when `aws_substrate.subzone_name` is empty or when no AWS subzone hosted
  zone ID can be resolved from config, harness env, or live stack output.
- `src/Prodbox/Infra/AwsEksSubzoneStack.hs::resolveAwsEksSubzoneStackConfig` loosens its
  pre-provision gate to require only `subzone_name` (the value Pulumi actually consumes
  at provision time); the hosted-zone ID becomes a post-provision value resolved from
  `aws_substrate.hosted_zone_id`, `PRODBOX_AWS_SUBSTRATE_HOSTED_ZONE_ID`, or the live
  `aws-eks-subzone` stack output. This removes the chicken-and-egg around the initial
  subzone provisioning while preserving the doctrine that downstream validations fail
  fast when no AWS-substrate value is available.
- The entry in [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md) for the
  helper fallback semantics closes when this code follow-up lands.

### Current Validation State

The substrate-aware code surface satisfies the no-fallback doctrine:

- `src/Prodbox/PublicEdge.hs::substratePublicFqdn` and `resolveSubstrateHostedZoneId` raise
  fail-fast `error` calls citing
  [development_plan_standards.md → M. Substrate coverage and independence (no fallback)](development_plan_standards.md#substrate-coverage-and-independence-no-fallback)
  when the AWS-substrate `subzone_name` is empty or when no AWS hosted-zone ID can
  be resolved from `aws_substrate.hosted_zone_id`, the harness-provided
  `PRODBOX_AWS_SUBSTRATE_HOSTED_ZONE_ID`, or the live `aws-eks-subzone` Pulumi
  output; the home-substrate branches resolve to `route53.zone_id` and
  `domain.demo_fqdn`.
- `src/Prodbox/Infra/AwsEksSubzoneStack.hs::resolveAwsEksSubzoneStackConfig` requires
  only `subzone_name` at pre-provision time; downstream AWS consumers enforce that
  a hosted-zone ID is available from config, harness env, or live stack output.
- `src/Prodbox/CLI/Charts.hs::withSubstrateEnvironment` and
  `src/Prodbox/TestValidation.hs::withSubstrateKubeconfigEnv` bracket-set
  `KUBECONFIG` + `AWS_ACCESS_KEY_ID` + `AWS_SECRET_ACCESS_KEY` +
  `AWS_DEFAULT_REGION` + `AWS_REGION` (+ optional `AWS_SESSION_TOKEN`) from
  `settings.aws.*` so EKS's `aws eks get-token` kubeconfig exec provider
  authenticates kubectl/helm subprocesses on the AWS substrate.
- `src/Prodbox/Lib/AwsSubstratePlatform.hs::extractRegionFromArn` preserves empty
  ARN segments (`splitKeepingEmpty`) so IRSA-role ARNs do not return the IAM
  account number as the region; the caller passes `aws.region` as the fallback.
  Helm string fields are passed via `--set-string` so the chart's string-typed
  `region` value is not parsed as `int64`.
- `src/Prodbox/Lib/AwsSubstratePlatform.hs::ensureAwsSubstrateAcmeRuntime` wraps
  its rendered `[Value]` manifest list as a `v1/List` object before
  `kubectl apply -f`, matching the home-substrate
  `Prodbox.CLI.Rke2::withTemporaryJsonManifest` pattern.
- `prodbox.dhall` imports `prodbox-config-types.dhall` so `aws_substrate`
  is materialized by the native `dhall` decoder.

The AWS-substrate platform install (`Prodbox.Lib.AwsSubstratePlatform.ensureAwsSubstratePlatformRuntime`)
currently lays down the lower-layer ingress + TLS pieces on EKS:

- `aws-load-balancer-controller` Helm release in `kube-system` (mirrors the home
  substrate's MetalLB layer).
- `envoy-gateway` Helm release in `envoy-gateway-system` via the upstream OCI
  chart (matches the home substrate's Envoy Gateway layer).
- `cert-manager` + `cert-manager-webhook` + `cert-manager-cainjector` in the
  `cert-manager` namespace via the upstream Jetstack chart.
- `route53-credentials` + `acme-eab-credentials` secrets and the
  `zerossl-dns01` `ClusterIssuer` rendered with `SubstrateAws` so DNS01
  challenges write into the per-substrate Route 53 subzone.

### Remaining Work

The substrate-platform install on EKS stands up the Harbor + MinIO + Percona operator layer that
the home substrate uses. Per the substrate-equivalence doctrine in [`../CLAUDE.md`](../CLAUDE.md),
[`../AGENTS.md`](../AGENTS.md), and [`substrates.md`](substrates.md), the AWS substrate runs the
same canonical chart set as the home substrate, so chart pods on EKS resolve
`127.0.0.1:30080/prodbox/...` through the EKS-side Harbor and node-local registry routing. The
May 19 implementation survey split this into the sub-sprints below; each closed its own validation
gate, and child Sprint `7.5.c.v` closed the parent live proof:

| Sub-sprint | Status | Scope |
|------------|--------|-------|
| [`7.5.c.i`](#sprint-75ci-substrate-aware-minio-chart-values-) | ✅ Done | Substrate-aware MinIO chart values (`gp2` EBS on AWS, hostPath PVC on home) |
| [`7.5.c.ii`](#sprint-75cii-eks-containerd-registry-mirror-config-injection-) | ✅ Done | EKS containerd registry-mirror config injection via privileged DaemonSet (no RKE2 `registries.yaml` equivalent on EKS) |
| [`7.5.c.iii`](#sprint-75ciii-eks-side-harbor--minio--percona-installs-) | ✅ Done | EKS-side MinIO + Harbor install wired into `ensureAwsSubstratePlatformRuntime` + Sprint 7.5.c.ii DaemonSet applied. Percona operator deferred to 7.5.c.iv (needs the image-mirror loop). |
| [`7.5.c.iv`](#sprint-75civ-in-cluster-image-mirror-job--percona-operator-) | ✅ Done | In-cluster image-mirror Job (crane-based) + Percona PostgreSQL operator install + steady-state MinIO reconcile wired into `ensureAwsSubstratePlatformRuntime` |
| [`7.5.c.v.b`](#sprint-75cvb-in-cluster-custom-image-build-on-eks-) | ✅ Done | In-cluster custom-image push for the single `prodbox-runtime` union image (consolidated by Sprint `1.45`; formerly `prodbox-gateway` + `prodbox-public-edge-workload`) via crane pod (docker save + kubectl cp + crane push --insecure). Live validation deferred to Sprint 7.5.c.v re-run. |
| [`7.5.c.v.c`](#sprint-75cvc-harness-preflight-residue-policy-bypassallresidueforharnessrefresh-) | ✅ Done | New `PulumiResiduePolicy` constructor `BypassAllResidueForHarnessRefresh` unblocks `runAwsIamHarnessSetup` preflight when the long-lived `aws-ses` stack is alive (the Sprint 7.7 `BypassPerRunResidueOnly` policy refused on `aws-ses`, blocking every harness-driven test run). |
| [`7.5.c.v.d`](#sprint-75cvd-operational-iam-policy-compaction--s3-grants-) | ✅ Done | Operational `prodbox` IAM inline policy compacted to fit under AWS's 2048-byte inline-user-policy cap: explicit `ec2:*` / `eks:*` action lists collapsed to service wildcards; new `SesCaptureBucketRead` / `SesCaptureObjectRead` (S3 grants on the SES capture bucket); policy submission switched to compact `Data.Aeson.encode`. |
| [`7.5.c.v.e`](#sprint-75cve-read-only-ses-grants-for-sprint-84-prerequisites-) | ✅ Done | New `SesReadOnly` statement (`ses:Describe*` / `Get*` / `List*`) so the harness IAM user can run the Sprint 8.4 `ses_sending_identity_verified` + `ses_receive_rule_set_active` prereq checks. |
| [`7.5.c.v.f`](#sprint-75cvf-silent-exit-failure-mode-in-substrate-aware-validation-bodies-) | ✅ Done on code-owned surface | Substrate-awareness threaded end-to-end through `prodbox host public-edge --substrate {home-local,aws}`, `runHostPublicEdge`, `queryRoute53RecordInZone`, `waitForPublicEdgeReady`, and the five sibling validation bodies. `runNativeValidation` now emits stderr breadcrumbs around every body so silent exit is structurally impossible at the runner level. Live `--substrate aws` re-run rolls up into Sprint `7.5.c.v`. |
| [`7.5.c.v`](#sprint-75cv-live-aws-substrate-canonical-suite-proof-) | ✅ Done | June 5 live runs proved AWS NLB-target DNS reconciliation, home-only gateway `dns_write_gate`, delegated-subzone pre-destroy record cleanup, per-run postflight teardown, Harbor-login retry, Keycloak public-token-endpoint readiness, the fixed VS Code OIDC redirect, API/WebSocket in-cluster JWKS backchannels, substrate-aware Harbor/MinIO admin routes, public DNS, and destructive lifecycle on AWS. The aggregate suite's remaining failure is Phase `8` invite-auth closure: `ValidationKeycloakInvite` must run before destructive `ValidationChartsStorage` / `ValidationLifecycle`, target the selected substrate public FQDN, and reach the Keycloak `/auth/admin` route used by operator invites. |

Sprint `7.5.c.v` flipped the substrate parity row in [`substrates.md`](substrates.md) to ✅ for the
Phase 7-owned substrate surface and closed Sprint `7.5.c`.

## Sprint 7.5.c.i: Substrate-Aware MinIO Chart Values ✅

**Status**: Done
**Implementation**: `src/Prodbox/CLI/Rke2.hs` (`renderMinioChartArgs`,
`minioSubstratePersistenceArgs`, `ensureMinioRuntime` signature extended
with `Substrate` parameter; `MinioImageSource` exported with `Eq`/`Show`).
**Docs to update**: `DEVELOPMENT_PLAN/phase-7-aws-substrate-foundations.md`,
`DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md`.

### Objective

Thread a `Substrate` parameter through the MinIO chart install so the AWS
substrate gets dynamic `gp2`-backed EBS persistence instead of the home
substrate's hostPath-bound PVC. Foundational for 7.5.c.iii.

### Deliverables

- `Prodbox.CLI.Rke2.renderMinioChartArgs :: Substrate -> MinioImageSource ->
  [String]` returns the flat `["--set", "k=v", …]` arg list, substrate-aware
  on the persistence block only:
  - `SubstrateHomeLocal` → retained `manual` StorageClass +
    `storage.size=20Gi` (hostPath-backed contract, right-sized to the default
    full-workflow capacity envelope).
  - `SubstrateAws` → `persistence.storageClass=gp2` + `persistence.size=20Gi`
    + no `existingClaim` so the chart dynamically provisions EBS against
    EKS's default storage class.
- `Prodbox.CLI.Rke2.minioSubstratePersistenceArgs` is the pure dispatcher;
  the substrate-agnostic core (`mode=standalone`, `replicas=1`, images,
  service type, resource requests) is shared.
- `ensureMinioRuntime` signature is now
  `FilePath -> Substrate -> MinioImageSource -> IO ExitCode`. Both
  home-substrate call sites in `ensureNativeInstallation` pass
  `SubstrateHomeLocal`.
- `MinioImageSource` derives `Eq`/`Show` and is exported so unit tests can
  build fixture tables.

### Validation

1. `prodbox check-code` exit 0.
2. `prodbox test unit` exit 0; new
   `describe "Sprint 7.5.c.i substrate-aware MinIO chart values"` block
   covers four fixture-comparison cases (home × bootstrap, home × steady,
   AWS × bootstrap, AWS × steady).
3. The home-substrate behavior is byte-for-byte unchanged; the
   `renderMinioChartArgs SubstrateHomeLocal _` arg list is identical to
   what `ensureMinioRuntime` rendered before this sprint.

### Remaining Work

None on the sprint-owned surface.

## Sprint 7.5.c.ii: EKS Containerd Registry-Mirror Config Injection ✅

**Status**: Done
**Implementation**: new `src/Prodbox/Lib/EksContainerdMirror.hs`
exposing `ContainerdMirrorConfig`, `defaultProdboxMirrorConfig`,
`eksContainerdMirrorBootstrapScript`, and
`eksContainerdMirrorDaemonSetManifest`. Library `exposed-modules`
in `prodbox.cabal`.
**Docs to update**: `DEVELOPMENT_PLAN/phase-7-aws-substrate-foundations.md`,
`DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md`.

### Objective

Make `127.0.0.1:30080/prodbox/...` image refs pullable from inside EKS
pods. The home substrate routes this via RKE2's
`/etc/rancher/rke2/registries.yaml` mechanism; EKS has no equivalent. The
sprint adds a privileged DaemonSet that, on every EKS node, writes the
containerd registry-mirror drop-in at
`/etc/containerd/certs.d/127.0.0.1:30080/hosts.toml` and signals
containerd to reload.

### Deliverables

- `Prodbox.Lib.EksContainerdMirror.eksContainerdMirrorDaemonSetManifest
  :: ContainerdMirrorConfig -> Value` renders the apps/v1 DaemonSet
  manifest in `kube-system` with `hostNetwork=true`, `hostPID=true`,
  a privileged init container, and a `hostPath` mount of `/etc` so
  the bootstrap script can read/write the host's containerd config.
  The long-running pause container keeps the pod alive across
  containerd restarts.
- `eksContainerdMirrorBootstrapScript` renders the init-container
  shell script that:
  1. Ensures `config_path = "/etc/containerd/certs.d"` is set in
     `/etc/containerd/config.toml` under
     `[plugins."io.containerd.grpc.v1.cri".registry]`. Amazon Linux
     2023 EKS AMIs from late 2024 onward already enable this; older
     AMIs need the patch.
  2. Writes the mirror drop-in at
     `/host/etc/containerd/certs.d/${HOST}/hosts.toml` with
     `capabilities = ["pull", "resolve"]` and `skip_verify = true`.
  3. Restarts containerd via `nsenter --target 1 --mount --uts --ipc
     --net --pid -- systemctl restart containerd` **only when** the
     drop-in or main config actually changed on disk
     (`RESTART_NEEDED` flag). Idempotent across rollouts.
- `defaultProdboxMirrorConfig` matches the home substrate's
  `127.0.0.1:30080` + `prodbox/` rewrite contract so chart-image refs
  work unchanged across both substrates per the substrate-equivalence
  doctrine.

### Validation

1. `prodbox check-code` exit 0.
2. `prodbox test unit` exit 0; new
   `describe "Sprint 7.5.c.ii EKS containerd registry-mirror
   DaemonSet"` block covers eight structural assertions on the
   rendered manifest + bootstrap script: apiVersion / kind /
   namespace, sprint label, hostNetwork + hostPID + privileged init
   container, `/etc` hostPath mount, drop-in path, `config_path`
   enablement, idempotence (`RESTART_NEEDED` + nsenter), TOML
   capabilities + skip_verify.
3. Live verification deferred to 7.5.c.v.

### Remaining Work

None on the sprint-owned surface. Effectful wiring of
`eksContainerdMirrorDaemonSetManifest` into
`ensureAwsSubstratePlatformRuntime` (apply via `kubectl apply -f`
inside a `v1/List` wrapper, then wait for DaemonSet rollout) lands
as part of Sprint `7.5.c.iii` since that sprint also installs the
Harbor NodePort service that the mirror routes to.

## Sprint 7.5.c.iii: EKS-Side Harbor + MinIO Install ✅

**Status**: Done
**Implementation**: `src/Prodbox/CLI/Rke2.hs`
(`ensureHarborRegistryRuntime` now takes a `Substrate` parameter and
delegates the docker-login + project-creation tail to the new
`ensureHarborProjectsForSubstrate` helper; `ensureMinioRuntime`,
`ensureHarborRegistryStorageBackend`, `ensureHarborRegistryRuntime`,
and `MinioImageSource` are now exposed from the module's
export list); `src/Prodbox/Lib/AwsSubstratePlatform.hs`
(new `applyEksContainerdMirrorDaemonSet` wrapper + new
`awsSubstratePlatformRuntimeStepDescriptions` pure listing;
`ensureAwsSubstratePlatformRuntime` sequence extended with four new
steps after the existing ACME step).
**Docs to update**: `DEVELOPMENT_PLAN/phase-7-aws-substrate-foundations.md`,
`DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md`.

### Objective

Wire the EKS-side MinIO + Harbor install + the Sprint 7.5.c.ii
containerd registry-mirror DaemonSet into
`ensureAwsSubstratePlatformRuntime` so that after the install
completes, EKS pods can resolve `127.0.0.1:30080/prodbox/...`
chart-image refs the same way home-substrate pods do.

### Deliverables

- `Prodbox.CLI.Rke2.ensureHarborRegistryRuntime` now takes a
  `Substrate` argument. On `SubstrateHomeLocal` it calls
  `ensureHarborDockerLogin` (operator-host docker authentication for
  the home-side image-mirror loop) before
  `createHarborProjects`; on `SubstrateAws` it skips the docker login
  because the operator host has no network path into the EKS-side
  Harbor NodePort. Bootstrap-project creation via the Harbor REST
  API works on both substrates.
- `Prodbox.Lib.AwsSubstratePlatform.applyEksContainerdMirrorDaemonSet`
  wraps `eksContainerdMirrorDaemonSetManifest defaultProdboxMirrorConfig`
  in a `v1/List` and applies it via `kubectl apply -f` against the
  EKS cluster. The bootstrap script lands on every EKS node, writes
  the containerd registry-mirror drop-in, and (when needed) restarts
  containerd. Idempotent across reapply.
- `ensureAwsSubstratePlatformRuntime` orchestration order, extended
  in this sprint, runs:
  1. `ensureAwsLoadBalancerControllerRuntime` — AWS LB Controller
     (Sprint 7.5.b.ii.b/d.II.α).
  2. `ensureAwsSubstrateEnvoyGatewayRuntime` — Envoy Gateway on EKS.
  3. `ensureAwsSubstrateCertManagerRuntime` — cert-manager on EKS.
  4. `ensureAwsSubstrateAcmeRuntime` — substrate-aware ACME
     `ClusterIssuer` + Route 53 credentials.
  5. **`applyEksContainerdMirrorDaemonSet`** — Sprint 7.5.c.ii
     DaemonSet so `127.0.0.1:30080` resolves to in-cluster Harbor
     once Harbor is up.
  6. **`ensureMinioRuntime SubstrateAws MinioBootstrapPublic`** —
     bootstrap MinIO from public registries onto `gp2`-backed EBS
     (Sprint 7.5.c.i chart-values support).
  7. **`ensureHarborRegistryStorageBackend`** — Kubernetes Job that
     creates the `prodbox-harbor-registry` bucket in MinIO and
     materializes the S3 credentials secret Harbor consumes.
  8. **`ensureHarborRegistryRuntime SubstrateAws`** — helm-install
     Harbor with NodePort `30080` + S3 backend pointing at MinIO,
     then wait for core/registry/nginx deployments + endpoint
     stability + bootstrap-project creation (no docker login on
     AWS).
- The pure step-list helper
  `awsSubstratePlatformRuntimeStepDescriptions :: [String]` is
  exported alongside the orchestrator so unit tests verify ordering
  without driving live subprocesses.

### Validation

1. `prodbox check-code` exit 0.
2. `prodbox test unit` exit 0; new
   `describe "Sprint 7.5.c.iii AWS-substrate platform orchestration"`
   block covers the eight-step canonical ordering, the
   mirror-before-Harbor invariant, and the
   MinIO-before-Harbor-storage-backend invariant.
3. The home-substrate behavior is preserved byte-for-byte: the
   `ensureHarborRegistryRuntime repoRoot SubstrateHomeLocal` call in
   `ensureNativeInstallation` still runs the docker-login +
   project-creation tail unchanged.
4. Live verification deferred to 7.5.c.v.

### Remaining Work

None on the sprint-owned surface. The Percona PostgreSQL operator
install was scoped into Sprint 7.5.c.iv because the operator pulls
its container image from `127.0.0.1:30080/prodbox/postgres-operator`,
which requires the Sprint 7.5.c.iv in-cluster image-mirror Job to
have populated Harbor first.

## Sprint 7.5.c.iv: In-Cluster Image-Mirror Job + Percona Operator ✅

**Status**: Done
**Implementation**: new `src/Prodbox/Lib/EksImageMirror.hs` exposing
`EksImageMirrorConfig`, `defaultEksImageMirrorConfig`,
`eksImageMirrorJobManifest`, and `eksImageMirrorCopyScript`; library
`exposed-modules` in `prodbox.cabal`. `src/Prodbox/Lib/AwsSubstratePlatform.hs`
adds `applyEksImageMirrorJob` (Job apply + `kubectl wait
--for=condition=complete`) and extends
`ensureAwsSubstratePlatformRuntime` with three new steps: image-mirror
Job, `ensurePostgresOperatorRuntime`, and the steady-state MinIO
reconcile. `src/Prodbox/CLI/Rke2.hs` exports
`ensurePostgresOperatorRuntime`.
**Docs to update**: `DEVELOPMENT_PLAN/phase-7-aws-substrate-foundations.md`,
`DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md`.

### Objective

Replace the home-substrate `mirrorRequiredImagesIntoHarbor`
(host-Docker + host-`ctr` based) with an in-cluster Kubernetes Job
on the AWS substrate. The operator host has no `ctr` access to EKS
nodes; the mirror loop must run from inside the cluster. After the
Job lands every required public image into EKS-side Harbor, the
Percona PostgreSQL operator can install (it pulls
`127.0.0.1:30080/prodbox/percona-postgresql-operator-mirror:...`)
and the steady-state MinIO reconcile can swap MinIO's bootstrap
public images for Harbor-mirrored copies.

### Deliverables

- `Prodbox.Lib.EksImageMirror.eksImageMirrorJobManifest ::
  EksImageMirrorConfig -> [(String, String)] -> Value` renders a
  `batch/v1` Job in `harbor` namespace running
  `gcr.io/go-containerregistry/crane:v0.20.2`. The container
  script authenticates to Harbor's in-cluster DNS endpoint
  (`harbor.harbor.svc.cluster.local`) and `crane copy`'s each
  `(upstream-source, chart-target)` pair — chart-targets like
  `127.0.0.1:30080/prodbox/...` get rewritten to the in-cluster
  endpoint for the push (in-pod-network `127.0.0.1` is the pod
  itself, not the EKS node). `crane copy` is idempotent on already-
  pushed digests so repeated rollouts are safe.
- `Prodbox.ContainerImage.requiredPublicImagePairs` (the existing
  upstream→Harbor mapping consumed by the home substrate's
  `mirrorClusterImagesOnce`) is the authoritative input — no new
  image inventory is introduced.
- `applyEksImageMirrorJob :: FilePath -> IO ExitCode` in
  `Prodbox.Lib.AwsSubstratePlatform` wraps the manifest in a
  `v1/List`, applies via `kubectl apply -f`, then blocks on
  `kubectl wait --for=condition=complete job/prodbox-image-mirror
  -n harbor --timeout=20m`. The Job's `backoffLimit=2` retries
  transient upstream registry failures within the single Job.
- `ensureAwsSubstratePlatformRuntime` orchestration extended with
  three new steps after `ensureHarborRegistryRuntime`:
  9. `applyEksImageMirrorJob` — populate Harbor with every required
     image before any chart pulls.
  10. `ensurePostgresOperatorRuntime` — Helm install the Percona
      operator (pulls operator image from Harbor via the Sprint
      7.5.c.ii containerd registry mirror).
  11. `ensureMinioRuntime SubstrateAws MinioSteadyStateHarbor` —
      reconcile MinIO with Harbor-mirrored images for the
      steady-state pod set.
- `awsSubstratePlatformRuntimeStepDescriptions` extended with the
  three new step names so unit tests verify the full eleven-step
  ordering contract.

### Validation

1. `prodbox check-code` exit 0.
2. `prodbox test unit` exit 0; new
   `describe "Sprint 7.5.c.iv EKS image-mirror Job"` block covers
   five structural assertions on the manifest + copy script:
   default-config Harbor admin contract, manifest declares
   `batch/v1 Job` with crane image + sprint label,
   `HARBOR_INTERNAL`/`USER`/`PASSWORD` env, chart-target rewrite to
   in-cluster Harbor DNS, and per-pair progress + auth-before-copy
   ordering. Extended
   `describe "Sprint 7.5.c.iii AWS-substrate platform orchestration
   (extended through 7.5.c.iv)"` block adds three ordering
   invariants: Harbor-before-mirror-before-Percona,
   Percona-before-steady-state-MinIO, plus the full 11-step
   sequence golden.
3. Live verification deferred to 7.5.c.v.

### Remaining Work

None on the sprint-owned surface.

## Sprint 7.5.c.v: Live AWS-Substrate Canonical-Suite Proof ✅

**Status**: Done — Sprints `7.5.c.v.b`, `7.5.c.v.c`, `7.5.c.v.d`,
`7.5.c.v.e`, and `7.5.c.v.f` have all landed in code. The June 4,
2026 live `prodbox test all --substrate aws` re-run proved the
silent-exit fix and reached chart deploys plus live public-edge
diagnostics on EKS: `GatewayClass` accepted, `Gateway` ready,
certificate ready, and the core app routes accepted. That run then
surfaced Route 53 target drift and delegated-subzone cleanup residue.
The June 5, 2026 live re-run proved the DNS/subzone fixes: AWS
`PUBLIC_ROUTE53_STATUS=in-sync` against the resolved Envoy NLB target,
`aws-subzone-destroy`, `eks-destroy`, and `test-destroy` all reported
destroyed/residue-check-passed, and the harness cleared operational
`aws.*` after per-run teardown. The initial remaining residual was the
first AWS canonical validation: `charts-vscode --substrate aws` reached
public-edge readiness but `/vscode` returned repeated HTTP 500 responses
instead of the expected Keycloak OIDC redirect. The worktree added a
Keycloak public-token-endpoint readiness gate, a longer VS Code redirect
retry window, bounded Harbor-login retries, and explicit VS Code OIDC
provider backchannel routing to the namespace-local `keycloak` Service.
The latest June 5 full AWS retry exercised those fixes: the Harbor-login
retry no longer blocked runtime restore, the public-token-endpoint
readiness gate completed before the redirect assertion, AWS chart deploy
reached public-edge-ready state, and `charts-vscode --substrate aws`
returned the expected OIDC redirect. The run then failed at
`charts-api --substrate aws`: `/api` returned HTTP 401 with Envoy's
`Jwks remote fetch is failed` response, narrowing the residual to the
API/WebSocket JWT `remoteJWKS` backchannel on EKS. Postflight again
destroyed the per-run subzone/EKS/test stacks with residue checks
passing and cleared operational `aws.*`. The next June 5 live retry
proved the API/WebSocket JWKS fix: `charts-vscode`, `charts-api`, and
`charts-websocket` all exited successfully on AWS, including the `/api`
external proof that previously returned Envoy's JWKS fetch failure. That
run then failed at `admin-routes --substrate aws`: `/harbor` returned
HTTP/2 404, and `host public-edge --substrate aws` reported
`HARBOR_HTTPROUTE_ACCEPTED=false` /
`HARBOR_SECURITY_POLICY_ATTACHED=false` (and the same false diagnostics
for MinIO). The residual narrowed to AWS substrate-platform install not
applying the Harbor/MinIO admin HTTPRoutes and, when rendered, using the
home `domain.demo_fqdn` instead of the AWS subzone host.

The final June 5 live retry rendered internal Keycloak JWKS URIs plus Envoy Gateway
`remoteJWKS.backendRefs` and `ReferenceGrant`s for the API and WebSocket
`SecurityPolicy` resources, and extends the AWS platform install with
substrate-aware Harbor/MinIO admin routes. `Prodbox.PublicEdge` owns the
shared substrate route/issuer URL helpers; `ensureAdminPublicEdgeRoutes`
now receives a `Substrate`; and `ensureAwsSubstratePlatformRuntime`
applies `ensureAdminPublicEdgeRoutes ... SubstrateAws` after
`ensureGatewayMinioBootstrap`, so the OIDC client secret can be derived
from the AWS-side master seed and the admin route manifests use
`aws.test.resolvefintech.com`. That live retry proved `admin-routes
--substrate aws` and the later Phase 7-owned public-edge / lifecycle
validations. The aggregate suite then failed only because
`ValidationKeycloakInvite` was still ordered after destructive
`ValidationLifecycle`; the ordering fix is owned by Sprint `8.6`.
First live run (May 19, 2026)
exercised the substrate-platform install on EKS end-to-end through
all 11 `ensureAwsSubstratePlatformRuntime` steps and surfaced six
architectural gaps; five landed as in-flight code fixes in that
session, the sixth landed as Sprint `7.5.c.v.b`.
**Implementation (this session's in-flight fixes)**:
`pulumi/aws-eks/Main.yaml` (EBS CSI driver IRSA role + addon, OIDC
trust-policy condition keys stripped of `https://` via
`fn::split`/`fn::join`); `src/Prodbox/Lib/EksImageMirror.hs` (crane
image tag `:debug`, `/busybox/sh` shebang + command,
`crane copy --insecure`, `crane auth login --insecure`);
`src/Prodbox/CLI/Rke2.hs` (new `createHarborProjectsAws` runs the
project-creation REST calls by `kubectl exec` into the already-running
`harbor-core` deployment and calling `harbor.harbor.svc.cluster.local`,
since the operator host's `127.0.0.1:30080` only resolves on RKE2 and a
new pre-mirror curl pod would create an image-bootstrap cycle);
`src/Prodbox/Lib/AwsSubstratePlatform.hs` (AWS-specific
`GatewayClass` / `EnvoyProxy` runtime with AWS Load Balancer
Controller NLB annotations and Harbor-mirrored Envoy image);
`src/Prodbox/TestRunner.hs` and `src/Prodbox/PublicEdge.hs` (the
harness reads the live `aws-eks-subzone` Pulumi output after
`aws-subzone-resources`, passes
`PRODBOX_AWS_SUBSTRATE_HOSTED_ZONE_ID` to child bootstrap commands,
and the public-edge helpers resolve the AWS hosted-zone ID from
config, harness env, or live stack output without falling back to the
home zone); `src/Prodbox/Lib/ChartPlatform.hs` (AWS chart plans render
`aws_substrate.subzone_name`, disable the gateway daemon
`dns_write_gate` on AWS, and leave the host-side public-edge
reconciler as the AWS A-record owner);
`src/Prodbox/Host.hs` and `src/Prodbox/Dns.hs` (`host public-edge
--substrate aws` reads the complete Route 53 A-record set, resolves
the Envoy NLB hostname to IPv4 targets, upserts the AWS subzone record
when the set drifts, and reports current vs expected DNS targets);
`src/Prodbox/Infra/AwsEksSubzoneStack.hs` (destroy path deletes
non-NS/SOA record sets in the delegated subzone before Pulumi destroys
the hosted zone); `src/Prodbox/TestValidation.hs` (`charts-vscode`
now waits for the public Keycloak token endpoint/realm to be usable
before expecting Envoy's OIDC filter to redirect `/vscode`, and its
redirect retry window covers slower AWS OIDC discovery convergence);
`src/Prodbox/CLI/Rke2.hs` (bounded retry for transient Harbor
`docker login` `unauthorized` / gateway / connection failures during
home-runtime restore after Harbor rolls; Harbor/MinIO admin
`SecurityPolicy` manifests now set explicit public authorization and
internal Keycloak token endpoints); `src/Prodbox/Lib/ChartPlatform.hs`
and `charts/vscode/templates/http-route.yaml` (VS Code `SecurityPolicy`
keeps the public issuer/authorization redirect but sends Envoy's OIDC
provider token backchannel to the in-cluster `keycloak` Service through
explicit `provider.backendRefs` plus an internal token endpoint);
`charts/api/templates/http-route.yaml`,
`charts/websocket/templates/http-route.yaml`, and
`src/Prodbox/Lib/ChartPlatform.hs` (API/WebSocket JWT `remoteJWKS` keeps
the public issuer/audience contract but fetches signing keys from
`http://keycloak.vscode.svc.cluster.local:8080/.../certs` through
cross-namespace `backendRefs`, with `ReferenceGrant`s in `vscode` for
the API and WebSocket namespaces); `src/Prodbox/PublicEdge.hs`,
`src/Prodbox/CLI/Rke2.hs`, and
`src/Prodbox/Lib/AwsSubstratePlatform.hs` (substrate-aware admin route
host/issuer/redirect rendering and AWS platform installation of the
Harbor/MinIO admin HTTPRoutes after gateway MinIO bootstrap).

### Objective

Live AWS-substrate canonical-suite proof: provision EKS + subzone,
run chart deploys + the five `--substrate aws` validations, then
auto-tear-down via the Sprint `7.6` harness postflight. Closes
Sprint `7.5.c` and flips the substrate parity row in
[`substrates.md`](substrates.md) to ✅.

### In-Flight Code Fixes Landed (May 19, 2026)

The first live run of `prodbox charts deploy gateway --substrate
aws` exercised the new 11-step `ensureAwsSubstratePlatformRuntime`
pipeline on a real EKS cluster (`aws-eks-test-cluster`, us-west-2,
2-node group, OIDC issuer
`E20FBA05EEE845723AAD42E683C41778`, Route 53 subzone
`Z01860472YFEU56UMS4W2`). The orchestration surfaced six gaps; five
are fixed and verified live:

1. **EBS CSI driver missing on EKS** (steps 6+ blocked: MinIO PVC
   `Pending` waiting on `ebs.csi.aws.com` provisioner that EKS no
   longer ships by default since the in-tree
   `kubernetes.io/aws-ebs` provisioner deprecation). Fixed in
   `pulumi/aws-eks/Main.yaml`: new IRSA role
   (`ebs-csi-driver`), `AmazonEBSCSIDriverPolicy` attachment, and
   `aws-ebs-csi-driver` managed addon. Verified live: PVCs against
   `gp2` bind to dynamic EBS volumes; MinIO + Harbor PVCs both
   landed.
2. **IAM trust-policy condition keys included `https://` prefix**
   (STS rejected every `AssumeRoleWithWebIdentity` with
   `AccessDenied`; per AWS IRSA docs the condition key must use the
   OIDC issuer URL **without** the scheme). Fixed in
   `pulumi/aws-eks/Main.yaml` by introducing
   `oidcIssuerHostPath` via `fn::split` + `fn::join`. Applied to
   both `awsLbControllerRole` and `ebsCsiDriverRole`. Verified live:
   manual `aws sts assume-role-with-web-identity` returned valid
   credentials; CSI controller pods transitioned from
   `CrashLoopBackOff` to `Running`.
3. **`gcr.io/go-containerregistry/crane:v0.20.2` tag does not exist
   on gcr.io** (image-mirror Job pod `ImagePullBackOff`). Fixed in
   `Prodbox.Lib.EksImageMirror.defaultEksImageMirrorConfig`:
   `mirrorJobImage = "gcr.io/go-containerregistry/crane:debug"`.
   Verified live: image pulled, container created.
4. **`gcr.io/go-containerregistry/crane:debug` ships only
   `/busybox/sh`, not `/bin/sh`** (distroless static-debian12:debug
   base). Fixed in
   `Prodbox.Lib.EksImageMirror.eksImageMirrorBootstrapScript`:
   shebang `#!/busybox/sh`; Job container command
   `["/busybox/sh", "-c", ...]`. Verified live: container started
   and ran the copy script.
5. **`crane copy` defaulted to HTTPS:443 against in-cluster
   Harbor** (Harbor exposes HTTP only per
   `expose.tls.enabled=false`; `i/o timeout` on `dial tcp
   <harbor-ClusterIP>:443`). Fixed in
   `Prodbox.Lib.EksImageMirror.renderCopyCommand`: appended
   `--insecure` to every `crane copy`. Verified live: Job completed
   in 5m02s pushing 21 images into the EKS-side Harbor.
6. **`ensureHarborProject` made REST calls to
   `127.0.0.1:30080`** (only resolves to Harbor on the RKE2 home
   substrate; on EKS the operator host has no path into the Harbor
   NodePort, so the harbor projects never got created and the
   image-mirror Job rejected pushes with `project prodbox not
   found`). Fixed in `src/Prodbox/CLI/Rke2.hs`: split
   `ensureHarborProjectsForSubstrate` into
   `createHarborProjectsHomeLocal` (the existing host-curl path)
   and `createHarborProjectsAws` (`kubectl exec` into the existing
   `harbor-core` deployment, then `curl -X POST` against
   `http://harbor.harbor.svc.cluster.local/api/v2.0/projects`).
   Verified live: the project-creation call returned HTTP 201 for both
   `prodbox` and `prodbox-gateway`; image-mirror Job's pushes succeeded.

After these five fixes, all 11 substrate-platform steps complete on
EKS, **including** Percona operator install + steady-state MinIO
reconcile from Harbor-mirrored images.

### Code-Side Sub-Sprint Closures Landed (May 19–20, 2026)

| Sub-sprint | Closure summary |
|------------|-----------------|
| `7.5.c.v.b` | In-cluster custom-image push for the single `prodbox-runtime` union image (consolidated by Sprint `1.45`) via a crane pod (`docker save` + `kubectl cp` + `crane push --insecure`). Closes the home-substrate-only `ensureRuntimeImage` gap on EKS. |
| `7.5.c.v.c` | New `PulumiResiduePolicy` constructor `BypassAllResidueForHarnessRefresh` lets the test-harness preflight refresh `aws.*` even when `aws-ses` is alive (the intended steady state). Closes the Sprint 7.7 over-tightening that blocked every harness-driven run on `aws-ses`. |
| `7.5.c.v.d` | Operational IAM inline policy compacted under AWS's 2048-byte cap: `ec2:*` / `eks:*` service wildcards replace 24+8 explicit actions, new `SesCaptureBucketRead` / `SesCaptureObjectRead` S3 grants on the SES capture bucket, compact `Data.Aeson.encode` for inline-policy submission. |
| `7.5.c.v.e` | New `SesReadOnly` (`ses:Describe*`/`Get*`/`List*`) statement grants the harness IAM user read-only SES access for the Sprint 8.4 `ses_sending_identity_verified` + `ses_receive_rule_set_active` prereqs. |

After these four sub-sprints landed, the May 20 re-run cleared every
prior gate (cabal unit + integration suites green, harness preflight
materializes `aws.*` against live `aws-ses`, the operational IAM user
provisions successfully, the three Sprint 8.4 SES prereqs pass).

### Validation

1. Local validation for the June 5 AWS VS Code OIDC readiness,
   Harbor-login retry, in-cluster OIDC-provider-backchannel,
   API/WebSocket JWKS-backchannel, and AWS admin-route substrate-host fixes
   passed before the next live AWS run: `cabal build --builddir=.build
   exe:prodbox`, binary refresh to `.build/prodbox`,
   `prodbox check-code`, `prodbox test unit` (650/650),
   `prodbox test integration cli` (30/30), `prodbox lint docs`,
   `prodbox docs check`, `git diff --check`, server-side
   `kubectl apply --dry-run=server` of the rendered API/WebSocket
   manifests, and the unit assertion that AWS admin route manifests render
   `aws.test.resolvefintech.com` all exited 0.
2. The five `--substrate aws` integration validations exit 0 under
   `prodbox test all --substrate aws`; the final June 5 live retry also
   proved `admin-routes --substrate aws` after the substrate-aware admin-route
   install.
3. `host public-edge --substrate aws` reports the Route 53 A-record set
   `in-sync` with the resolved Envoy NLB IPv4 targets, not the operator
   host public IP.
4. AWS residue scan returns zero per-run resources (EKS, NAT, EBS, IAM,
   hosted-zone records, ALBs). The long-lived `aws-ses` stack is
   intentionally retained per the long-lived cross-substrate
   shared-infrastructure class.

### Remaining Work

None on the Phase 7-owned AWS substrate surface. The aggregate AWS run's
remaining failure is Sprint `8.6`: `ValidationKeycloakInvite` must run before
destructive `ValidationChartsStorage` / `ValidationLifecycle`, use the selected
substrate public FQDN, and route Keycloak admin API calls through `/auth/admin`
while the invite-auth proof still has a live EKS cluster and Pulumi stack snapshot.

## Sprint 7.5.c.v.b: In-Cluster Custom-Image Build on EKS ✅

**Status**: Done
**Implementation**: new `src/Prodbox/Lib/EksCustomImagePush.hs`
exposing `EksCustomImagePushConfig`,
`defaultEksCustomImagePushConfig`, `eksCustomImagePushPodManifest`,
and `rewriteChartRefForInClusterPush`; library `exposed-modules` in
`prodbox.cabal`. `src/Prodbox/CLI/Rke2.hs` extends
`ensureCustomImageVariants` to dispatch on `Substrate`:
`SubstrateHomeLocal` keeps the existing host-Docker login + push +
`ctr` import path (`ensureCustomImageVariantsHomeLocal`);
`SubstrateAws` uses a new `ensureCustomImageVariantsAws` path that
builds on the operator host, `docker save`'s the result to
`.prodbox-state/tmp/prodbox-custom-image.tar`, applies the crane
push pod manifest, `kubectl cp`'s the tarball in, and
`kubectl exec`'s `crane push --insecure` once per requested tag.
New `ensureGatewayImagesForSubstrate` and
`ensurePublicEdgeWorkloadImageForSubstrate` exports wire the
substrate parameter through. `Prodbox.Lib.AwsSubstratePlatform`
orchestrator extended with two new steps between the image-mirror
Job and Percona operator install.
**Docs to update**: `DEVELOPMENT_PLAN/phase-7-aws-substrate-foundations.md`,
`DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md`.

### Objective

Build and publish the single custom prodbox union runtime image
(`prodbox-runtime`; consolidated by Sprint `1.45` from the former
`prodbox-gateway` + `prodbox-public-edge-workload`) so it lands in
EKS-side Harbor and the gateway / public-edge chart pods can pull
them via the Sprint `7.5.c.ii` containerd registry-mirror
DaemonSet. The home substrate's `ensureGatewayImages` /
`ensurePublicEdgeWorkloadImage` use host-Docker `docker push` to
`127.0.0.1:30080` and `sudo ctr image import` against the RKE2 node
containerd socket — neither path applies on EKS.

### Deliverables

- `Prodbox.Lib.EksCustomImagePush.eksCustomImagePushPodManifest ::
  EksCustomImagePushConfig -> Value` renders a long-running `v1`
  Pod in the `harbor` namespace running
  `gcr.io/go-containerregistry/crane:debug` with `sleep infinity`
  as its entrypoint. A 4 GiB `emptyDir` at `/data` is the
  `kubectl cp` target. The `:debug` variant ships `/busybox/sh` and
  the `crane` binary at `/ko-app/crane`.
- `Prodbox.Lib.EksCustomImagePush.rewriteChartRefForInClusterPush ::
  EksCustomImagePushConfig -> String -> String` rewrites
  `127.0.0.1:30080/<repo>:<tag>` chart-image refs to
  `harbor.harbor.svc.cluster.local/<repo>:<tag>` so `crane push`
  targets in-cluster Harbor over its in-cluster DNS endpoint while
  the manifest path matches what downstream chart pods consume via
  the registry-mirror DaemonSet.
- `Prodbox.CLI.Rke2.ensureCustomImageVariantsForSubstrate`
  dispatches on `Substrate`; the legacy
  `ensureCustomImageVariants` is preserved as a
  `SubstrateHomeLocal` alias so existing call sites need no change.
  New `ensureGatewayImagesForSubstrate` and
  `ensurePublicEdgeWorkloadImageForSubstrate` exports thread the
  substrate through to the variant function.
- `Prodbox.Lib.AwsSubstratePlatform.ensureAwsSubstratePlatformRuntime`
  orchestration is now **13 steps**: the eleven from Sprint
  `7.5.c.iv` plus
  `ensureGatewayImagesForSubstrate SubstrateAws` and
  `ensurePublicEdgeWorkloadImageForSubstrate SubstrateAws` inserted
  between `applyEksImageMirrorJob` and
  `ensurePostgresOperatorRuntime` (so Harbor is populated with
  mirrored upstreams + custom images before any later Helm release
  pulls).
- The new AWS-substrate IO path: build via operator-host Docker
  (the operator already has a working Docker daemon for the home
  substrate), `docker save` to
  `.prodbox-state/tmp/prodbox-custom-image.tar`, apply the crane
  push pod, `kubectl wait` for Ready (120 s timeout), `kubectl cp`
  the tarball to `/data/image.tar`, run `kubectl exec … /ko-app/crane
  push /data/image.tar <rewritten-target> --insecure` for each
  requested tag (`<repo>:<prodboxId-derived-tag>` and `<repo>:latest`),
  delete the pod. The `ctr` import step from the home path is
  intentionally omitted — EKS nodes pull from in-cluster Harbor via
  the registry-mirror DaemonSet.

### Validation

1. `prodbox check-code` exit 0.
2. `prodbox test unit` exit 0; new
   `describe "Sprint 7.5.c.v.b EKS custom-image push pod"` block
   covers five structural assertions on the pod manifest + the
   chart-ref rewrite. Extended
   `describe "Sprint 7.5.c.iii AWS-substrate platform orchestration
   (extended through 7.5.c.iv + 7.5.c.v.b)"` block adds a
   thirteen-step golden + the mirror→gateway→workload→Percona
   ordering invariant.
3. The home-substrate behavior is preserved byte-for-byte: the
   default `ensureCustomImageVariants` alias delegates to the
   `SubstrateHomeLocal` path; existing `ensureGatewayImages` and
   `ensurePublicEdgeWorkloadImage` call sites keep working
   unchanged.
4. Live verification of the crane push pod end-to-end is deferred
   to the Sprint `7.5.c.v` re-run (which provisions EKS + subzone,
   drives the full 13-step orchestration, and expects gateway pods
   to reach Ready).

### Remaining Work

None on the sprint-owned surface. The next live `prodbox charts
deploy gateway --substrate aws` run is Sprint `7.5.c.v`'s
re-attempt at the five `--substrate aws` integration validations.

## Sprint 7.5.c.v.c: Harness Preflight Residue Policy `BypassAllResidueForHarnessRefresh` ✅

**Status**: Done (May 20, 2026)
**Implementation**: `src/Prodbox/CLI/Command.hs` (new
`PulumiResiduePolicy` constructor `BypassAllResidueForHarnessRefresh`,
documented as harness-internal only and never CLI-settable);
`src/Prodbox/Aws.hs` (`applyAwsTeardown` case-of extended with the
new constructor; `runAwsIamHarnessSetup` preflight switched from
`BypassPerRunResidueOnly` to `BypassAllResidueForHarnessRefresh`;
`runAwsIamHarnessTeardown` postflight kept `BypassPerRunResidueOnly`
at this sprint — **later switched to `BypassAllResidueForHarnessRefresh`
by Sprint 7.9**, which corrected the stale "preserve `aws.*` to destroy
`aws-ses`" premise);
`test/unit/Main.hs` (Sprint 7.7 residue-policy describe block extended
with Scenarios M and N covering the `aws-ses`-live and
all-four-stacks-present cases).
**Docs to update**: `DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md`,
`DEVELOPMENT_PLAN/phase-7-aws-substrate-foundations.md`.

### Objective

Unblock harness-driven test runs when the long-lived `aws-ses` stack
is alive. The Sprint 7.7 `BypassPerRunResidueOnly` policy refuses on
long-lived shared infrastructure (`aws-ses`), which protects
operator-driven teardowns from stranding `aws.*`. Applied to
`runAwsIamHarnessSetup`'s preflight, however, that protection is
misapplied: the preflight is a transient `aws.*` refresh paired with
an immediate re-materialization driven by the `aws_admin_for_test_simulation.*`
test fixture (Sprint `7.16` sources it from `test-secrets.dhall`)
in the same function call, so neither per-run nor long-lived residue
strands anything across that gap. Refusing on `aws-ses` blocked every
test-harness run because `aws-ses` is the intended steady state.

### Deliverables

- New `PulumiResiduePolicy` constructor
  `BypassAllResidueForHarnessRefresh` in `src/Prodbox/CLI/Command.hs`,
  documented in the Haddock above the ADT as harness-internal only,
  never CLI-settable, scoped to start-of-run preflight refresh.
- `applyAwsTeardown` extended with a straight `runTeardown` branch on
  the new constructor.
- `runAwsIamHarnessSetup` preflight teardown switched to
  `BypassAllResidueForHarnessRefresh`; `runAwsIamHarnessTeardown`
  (postflight) keeps `BypassPerRunResidueOnly` at this sprint on the
  premise that the operator may preserve `aws.*` to destroy `aws-ses`
  at end-of-run. **(Superseded by Sprint 7.9: that premise was a
  pre-Sprint-4.10 artifact — `aws-ses` is admin-credentialed post-4.10,
  so the postflight was switched to `BypassAllResidueForHarnessRefresh`
  to stop stranding the operational IAM user.)** (Sprint `7.16` supersedes the
  stored-admin-in-`prodbox-config.dhall` model: real `aws-ses` ops prompt for the
  ephemeral elevated credential via the interactive `SecretRef.Prompt`, which the
  harness simulates from the `test-secrets.dhall` fixture.)
- Two new unit tests in
  `test/unit/Main.hs::"Sprint 7.7 applyAwsTeardown residue policy"`:
  Scenario M (`aws-ses` live only, policy proceeds) and Scenario N
  (all four per-run + long-lived stacks live, policy proceeds).

### Validation

1. `prodbox check-code` exit 0.
2. `prodbox test unit` exit 0 (380 tests after the two new scenarios).
3. Live verification: harness preflight materializes operational
   `aws.*` successfully on every run regardless of `aws-ses` state.

### Remaining Work

None on the sprint-owned surface.

## Sprint 7.5.c.v.d: Operational IAM Policy Compaction + S3 Grants ✅

**Status**: Done (May 20, 2026)
**Implementation**: `src/Prodbox/Aws.hs` (`extraPolicyStatements`:
`Ec2HaTestStackLifecycle` 24-action explicit list compressed to
`Ec2TestStackLifecycle` / `ec2:*`; `EksTestStackLifecycle` 8-action
list compressed to `eks:*`; new `SesCaptureBucketRead` and
`SesCaptureObjectRead` statements granting `s3:GetBucketLocation` +
`s3:ListBucket` + `s3:GetObject` on the SES capture bucket; inline
policy submission in `ensureOperationalIamUser` switched from pretty
`AesonPretty` to compact `Data.Aeson.encode`); `test/unit/Main.hs`
(`buildIamPolicyDocument` Sid assertion updated for the renamed
`Ec2TestStackLifecycle` + new `SesCaptureBucketRead` /
`SesCaptureObjectRead` Sids); `test/integration/CliSuite.hs`
(`prodbox aws policy --tier full` golden assertions updated for the
same Sid set).
**Docs to update**: `DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md`,
`DEVELOPMENT_PLAN/phase-7-aws-substrate-foundations.md`.

### Objective

Keep the operational `prodbox` IAM user's inline policy under the AWS
2048-byte limit while adding the S3 grants the harness needs to read
the SES capture bucket during `keycloak-invite` validation. The
explicit Ec2/Eks action lists were the biggest contributors to policy
size; the operational user creates and destroys whole VPCs / clusters
by design via the `aws-test` / `aws-eks` Pulumi stacks, so service
wildcards are operationally equivalent.

### Deliverables

- `Ec2HaTestStackLifecycle` Sid renamed to `Ec2TestStackLifecycle`
  and its action list collapsed to `["ec2:*"]`.
- `EksTestStackLifecycle` action list collapsed to `["eks:*"]`.
- New `SesCaptureBucketRead` statement (`s3:GetBucketLocation`,
  `s3:ListBucket`) scoped to `arn:aws:s3:::prodbox-ses-capture`.
- New `SesCaptureObjectRead` statement (`s3:GetObject`) scoped to
  `arn:aws:s3:::prodbox-ses-capture/*`.
- `ensureOperationalIamUser` inline-policy submission switched from
  `AesonPretty.encodePretty'` to compact `Data.Aeson.encode`. The
  pretty form is reserved for the operator-facing
  `prodbox aws policy` rendering surface, which is unchanged.
- Compact-encoded policy size: ~1.5 kB (well under the 2 kB cap).

### Validation

1. `prodbox check-code` exit 0.
2. `prodbox test unit` exit 0 (extended `buildIamPolicyDocument` Sid
   assertion at `test/unit/Main.hs:508`).
3. `prodbox test integration cli` exit 0 (extended
   `prodbox aws policy --tier full` golden assertion at
   `test/integration/CliSuite.hs:105`).
4. Live verification: the harness creates the operational IAM user
   successfully and the Sprint 8.4 SES prereqs pass.

### Remaining Work

None on the sprint-owned surface.

## Sprint 7.5.c.v.e: Read-Only SES Grants for Sprint 8.4 Prerequisites ✅

**Status**: Done (May 20, 2026)
**Implementation**: `src/Prodbox/Aws.hs::extraPolicyStatements`
(new `SesReadOnly` statement with `ses:Describe*` / `ses:Get*` /
`ses:List*` on `"*"`); `test/unit/Main.hs` and
`test/integration/CliSuite.hs` (Sid-set assertions extended).
**Docs to update**: `DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md`,
`DEVELOPMENT_PLAN/phase-7-aws-substrate-foundations.md`.

### Objective

Grant the operational `prodbox` IAM user the read-only SES access it
needs to run the Sprint 8.4 prerequisite checks:
`ses_sending_identity_verified` calls
`aws ses get-identity-verification-attributes`;
`ses_receive_rule_set_active` calls
`aws ses describe-active-receipt-rule-set`. Without the grant, both
prereqs failed with `AccessDenied` on the harness IAM user.

### Deliverables

- New `SesReadOnly` statement in the `PolicyFull` extras list,
  granting `ses:Describe*` / `ses:Get*` / `ses:List*` on `"*"`. The
  wildcards keep the harness within least-privilege bounds (no
  sending, no rule-set mutation) while covering any future read-only
  SES prereq additions.

### Validation

1. `prodbox check-code` exit 0.
2. `prodbox test unit` exit 0 (Sid assertion extended).
3. `prodbox test integration cli` exit 0 (golden assertion extended).
4. Live verification: the three Sprint 8.4 SES prereqs pass under the
   harness IAM user.

### Remaining Work

None on the sprint-owned surface.

## Sprint 7.5.c.v.f: Silent-Exit Failure Mode in Substrate-Aware Validation Bodies ✅

**Status**: Done on the code-owned surface (May 20, 2026); live
`--substrate aws` re-run observation is rolled up into Sprint
`7.5.c.v`.
**Blocked by**: none (this sprint owns its own diagnosis + fix).
**Blocks**: Sprint `7.5.c.v` (live AWS-substrate canonical-suite proof).
**Implementation**: `src/Prodbox/CLI/Command.hs`
(`HostCommand.HostPublicEdge` now carries `Substrate`);
`src/Prodbox/CLI/Spec.hs` (`host public-edge` parser + leaf threads
`--substrate {home-local,aws}`; promoted `substrateOption :: OptionSpec`
out of `testGroupSpec`'s where-clause for reuse);
`src/Prodbox/Host.hs::runHostPublicEdge` now takes `Substrate`, uses
`substratePublicFqdn` / `substrateHostedZoneId` (no fallback), and
emits a stdout breadcrumb `PUBLIC_EDGE_SUBSTRATE=<id>` so the
substrate is visible in the operator log;
`src/Prodbox/Dns.hs` (new `queryRoute53RecordInZone` takes an
explicit hosted-zone id; legacy `queryRoute53Record` is now a
home-substrate adapter);
`src/Prodbox/TestValidation.hs::runNativeValidation` now emits a
stderr breadcrumb `[validation=<id> substrate=<id>] entering body`
before the body and `... body exit=<ExitCode>` after, so a silent
exit is structurally impossible at the runner level; the four
substrate-aware public-edge validation bodies
(`runChartsVscodeValidation`, `runChartsApiValidation`,
`runChartsWebsocketValidation`, `runAdminRoutesValidation`) and the
shared `waitForPublicEdgeReady` thread `Substrate` and pass
`--substrate <id>` to the spawned `prodbox host public-edge`
subprocess; `runPublicDnsValidation` accepts a `Substrate` parameter
to keep the runner-level dispatch uniform but its current body still
reads `route53.zone_id` from `prodbox-config.dhall` rather than the
substrate-aware hosted-zone helper, so its substrate-aware
assertions land alongside the live AWS-substrate re-run in Sprint
`7.5.c.v`; `src/Prodbox/TestRunner.hs::runWaitForPublicEdgeReady`
takes `Substrate` (the home-cluster bootstrap and postflight
restore paths pass `SubstrateHomeLocal` explicitly).
**Docs to update**: `DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md`
(move the Pending Removal row to Completed once the live re-run lands
in Sprint `7.5.c.v`), `DEVELOPMENT_PLAN/phase-7-aws-substrate-foundations.md`
(this status flip).

### Objective

Diagnose and fix the silent-exit failure mode where every
`--substrate aws` integration validation body returns without
producing any output and without calling `failWith`. Symptom is
reproducible: the May 20, 2026 live re-run (run5 and run6) reached
Phase 2/2, the first named validation header
`Validation: charts-vscode (substrate=aws)` emitted, then immediately
the harness postflight `Auto-destroying per-run AWS Pulumi stacks
...` fired. No body output, no `Public edge diagnostic` block, no
`failWith` stderr message, no AWS-CLI subprocess logs. The expected
output of `waitForPublicEdgeReady repoRoot` (which shells out to
`prodbox host public-edge` and streams its stdout/stderr through) is
absent.

### Suspected Root Cause

A substrate-aware code path under `runChartsVscodeValidation` /
`waitForPublicEdgeReady` lacks an AWS branch and short-circuits
without `failWith` — consistent with the Sprint 7.5.b.iii
substrate-independence doctrine still being partial on the
test-validation layer. The same defect likely affects
`runChartsApiValidation`, `runChartsWebsocketValidation`,
`runAdminRoutesValidation`, and `runPublicDnsValidation`, because all
five share the same `waitForPublicEdgeReady` plumbing.

### Deliverables

- Diagnostic breadcrumb (stderr-side) at the top of
  `runChartsVscodeValidation` to confirm whether the body is entered
  at all under `substrate=aws`. If the body is entered, trace the
  exit-without-output through `waitForPublicEdgeReady` and its
  subprocess wiring.
- A `failWith` (or a substrate-aware code branch) on whatever
  short-circuit path is currently returning silently.
- Identical fix applied to the four sibling validations.
- A unit-level guard against the regression — at minimum, a fixture
  asserting that a substrate-aware validation function never returns
  `ExitFailure` without emitting at least one stderr line.

### Validation

1. `prodbox check-code` exit 0.
2. `prodbox test unit` exit 0 (new regression guard).
3. A single targeted live re-run:
   `./.build/prodbox test integration charts-vscode --substrate aws`
   exits with explicit diagnostic output (success or failure), not
   silently. If the previous defect was a missing AWS branch, the
   substrate-aware fix is observable on rerun.

### Remaining Work

None on the sprint-owned silent-exit surface. Code, doctrine
alignment, and unit-level guards (golden-test goldens for the new
`--substrate` parser leaf and the breadcrumb-emitting runner shape)
landed May 20, 2026. The June 4, 2026 live
`prodbox test all --substrate aws` re-run proved the validation bodies
now enter and emit public-edge diagnostics instead of returning
silently; the DNS mismatch surfaced by that run and the June 5 VS Code
OIDC readiness failure are both owned by the parent Sprint `7.5.c.v`.

## Sprint 7.6: AWS Harness Orphan-Safety Guards ✅

**Status**: Done
**Implementation**: `src/Prodbox/Aws.hs` (`applyAwsTeardown`,
`checkPulumiResidueBeforeTeardown`, `renderPulumiResidueRefusal`,
`AwsTeardownInput` flag); `src/Prodbox/TestRunner.hs`
(`runWithAwsHarnessCleanup`, `awsPostflightDestroyActions`);
`src/Prodbox/CLI/Command.hs` (`AwsTeardownFlags` type, extended
`AwsTeardown` constructor); `src/Prodbox/CLI/Spec.hs`
(`awsTeardownFlagsParser` for `--allow-pulumi-residue`);
`src/Prodbox/Infra/AwsEksTestStack.hs`,
`src/Prodbox/Infra/AwsEksSubzoneStack.hs`,
`src/Prodbox/Infra/AwsTestStack.hs`,
`src/Prodbox/Infra/AwsSesStack.hs`
(`<stack>HasLiveResources` predicates).
**Docs to update**: `DEVELOPMENT_PLAN/substrates.md`,
`DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md`,
`documents/engineering/aws_integration_environment_doctrine.md`

### Objective

Make it impossible to orphan AWS resources by accident. Two guards close the gap
identified in the May 19, 2026 audit:

- **Refuse path** — `prodbox aws teardown` refuses to delete the operational IAM
  user while any Pulumi-managed stack (`aws-eks`, `aws-eks-subzone`, `aws-test`,
  `aws-ses`) still reports live resources. The failure message names the
  offending stack(s) and the canonical destroy command. Even though `aws-ses`
  is long-lived shared infrastructure that the auto-destroy path does not
  touch, the refuse path still covers it — deleting operational creds while
  SES is up strands the SES stack from the supported destroy surface.
- **Auto-destroy path** — on any test-run exit (success, failure, **and**
  Ctrl-C), the harness destroys every **per-run** Pulumi stack the suite touched
  (`aws-eks`, `aws-eks-subzone`, `aws-test`) before clearing operational
  `aws.*`. The `aws-ses` stack is **explicitly excluded** from auto-destroy per
  the long-lived cross-substrate shared-infrastructure class in
  [substrates.md → Resource Lifecycle Classes](substrates.md#resource-lifecycle-classes).

Sprint `7.6` closes the `aws teardown` gap. The companion work — the
`aws-ses` Pulumi-backend decoupling, the symmetric refuse-path on
`prodbox rke2 delete`, the K8s-operator-created AWS leak classes
(CSI volumes, LBC load balancers, cert-manager TXTs, direct-aws-CLI
shell-out Route 53 records), and the operator-only `prodbox nuke` —
is owned by Sprints `4.10` / `4.11` / `4.12` / `4.13` under phase 4.
See
[../documents/engineering/lifecycle_reconciliation_doctrine.md](../documents/engineering/lifecycle_reconciliation_doctrine.md)
for the consolidated doctrine.

### Deliverables

- `src/Prodbox/Aws.hs::applyAwsTeardown` returns `IO (Either String
  IamTeardownResult)`. Before any access-key / policy / user deletion
  it calls `checkPulumiResidueBeforeTeardown`, which queries each of
  the four Pulumi stack predicates and returns the list of live
  stacks paired with the canonical destroy command for each. A
  non-empty residue list short-circuits with a `Left` carrying the
  human-readable refusal message rendered by
  `renderPulumiResidueRefusal`. The `--allow-pulumi-residue` flag
  (parsed into `AwsTeardownFlags.teardownAllowPulumiResidue` and
  threaded onto `AwsTeardownInput.awsTeardownAllowPulumiResidue`)
  bypasses the residue check.
- `src/Prodbox/TestRunner.hs::runWithAwsHarnessCleanup` wraps the
  suite body with `Control.Exception.try` so synchronous suite
  failures **and** async exceptions (Ctrl-C / SIGTERM) both flow
  through the same cleanup sequence: `awsPostflightDestroyActions`
  unconditionally runs `prodbox pulumi aws-subzone-destroy --yes`,
  `pulumi eks-destroy --yes`, and `pulumi test-destroy --yes` (in
  that order, idempotent on empty stacks) before
  `runManagedAwsHarnessTeardown` clears operational `aws.*`. On
  async exception the cleanup runs first, then `throwIO` re-raises
  so the operator-visible signal is preserved.
- `supportedRuntimePostflightActions` no longer carries the Pulumi
  destroy commands (those moved to `awsPostflightDestroyActions`).
  It retains its other purpose: runtime restore via `rke2 reconcile`
  + chart redeploy + public-edge readiness wait, on the success
  path.
- The `aws-ses` stack is **explicitly excluded** from
  `awsPostflightDestroyActions` per the long-lived cross-substrate
  shared-infrastructure class in
  [substrates.md → Resource Lifecycle Classes](substrates.md#resource-lifecycle-classes).
  It remains covered by `checkPulumiResidueBeforeTeardown` — deleting
  operational creds while SES is up would strand SES from the
  supported destroy surface.
- `prodbox aws teardown --allow-pulumi-residue` parses through
  `AwsTeardownFlags` in `src/Prodbox/CLI/Command.hs` and
  `awsTeardownFlagsParser` in `src/Prodbox/CLI/Spec.hs`. Documented
  in
  `documents/engineering/aws_integration_environment_doctrine.md`
  next to the refuse-path doctrine.
- Each of `src/Prodbox/Infra/AwsEksTestStack.hs`,
  `src/Prodbox/Infra/AwsEksSubzoneStack.hs`,
  `src/Prodbox/Infra/AwsTestStack.hs`, and
  `src/Prodbox/Infra/AwsSesStack.hs` exposes
  `<stack>HasLiveResources :: FilePath -> IO Bool`. Implementation
  is a `doesFileExist` against
  `.prodbox-state/<stack>/stack-snapshot.json` — present implies
  live, matching the existing harness contract whereby
  `save<Stack>StackSnapshot` writes the file on `pulumi up` success
  and `clear<Stack>StackSnapshot` removes it on `pulumi destroy`.
  **Pre-doctrine pragma** — the file-existence approximation is on
  the cleanup ledger (see
  [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md)),
  scheduled for removal by Sprint `4.16` in favor of
  `<stack>ResidueStatus` queries against the actual MinIO (per-run)
  or S3 (long-lived) Pulumi backend per
  [secret_derivation_doctrine.md](../documents/engineering/secret_derivation_doctrine.md)
  and [lifecycle_reconciliation_doctrine.md §3](../documents/engineering/lifecycle_reconciliation_doctrine.md).

### Validation

1. `prodbox check-code` exit 0.
2. `prodbox test unit` covers the regression matrix in
   `test/unit/Main.hs::describe "Sprint 7.6 AWS harness
   orphan-safety"`: Scenario A (`aws-eks` snapshot present →
   refusal names eks-destroy); Scenario B (no snapshots → residue
   empty so cleanup proceeds); Scenario C (subzone + aws-test
   snapshots present → refusal names both); Scenario D (`aws-ses`
   snapshot present → refusal names `aws-ses-destroy --yes`); and
   all-four-present (refusal lists every stack in the canonical
   eks → subzone → test → ses order).
3. Live regression (operator-driven, deferred):
   `prodbox pulumi eks-resources` → `prodbox aws teardown` returns
   non-zero with the actionable message; the EKS cluster still has
   all its resources; subsequent
   `prodbox pulumi eks-destroy --yes` succeeds. Then
   `prodbox aws teardown` (with no remaining stacks) succeeds.
4. Live regression (operator-driven, deferred): `prodbox test all`
   interrupted via SIGINT mid-suite leaves zero per-run Pulumi
   resources alive after the harness unwinds (`pulumi stack
   --show-urns` returns empty for `aws-eks`, `aws-eks-subzone`,
   `aws-test`; the persistent `aws-ses` stack remains).

### Remaining Work

None on the sprint-owned surface. The two live operator regressions
above are documentation of the closed contract, not remaining
implementation work — `prodbox test integration` does not yet
exercise the SIGINT cancellation path on real AWS because doing so
requires a full live AWS substrate cycle.

## Sprint 7.7: Generalized `aws teardown` + Harness Orphan-Safety + Admin-Credential Prompt UX ✅

**Status**: Done (May 19, 2026)
**Blocked by**: none (Sprint `7.6` was closed; this sprint extended and generalized the
contract Sprint `7.6` introduced)
**Implementation**: `src/Prodbox/CLI/Command.hs` (new `PulumiResiduePolicy` enum +
`AwsTeardownFlags.teardownResiduePolicy :: PulumiResiduePolicy` field);
`src/Prodbox/Aws.hs` (refactored `applyAwsTeardown` with per-run vs long-lived partition
via `partitionResidueByLifecycle` and `DestroyPulumiResidueFirst` branch that dispatches
through new `dispatchPulumiDestroysForResidue`; pure helpers `perRunStackNames`,
`longLivedStackNames`, `pulumiDestroyPlanForResidue`, `renderPulumiResidueLongLivedRefusal`;
refactored `interactiveAwsTeardownInput` to `IO (Either String (Maybe AwsTeardownInput))`
shape with file-based residue check before any prompt and a "nothing to do" early-exit
when residue is empty AND operational `aws.*` is empty;
refactored `promptAdminCredentials` to use new `sessionTokenPromptShape` /
`promptSessionTokenForKey` for `AKIA…` vs `ASIA…` auto-detection; renamed
user-facing "Elevated AWS …" prompt strings to "Temporary admin AWS …"; updated
`runAwsIamHarnessSetup` and `runAwsIamHarnessTeardown` to use
`BypassPerRunResidueOnly` instead of the unconditional bypass that allowed the May 19
orphan reproduction); `src/Prodbox/CLI/Spec.hs` (`awsTeardownFlagsParser` uses the
`flag'` + `<|>` + `pure` idiom for `--allow-pulumi-residue` and `--destroy-pulumi-residue`,
which optparse-applicative renders as `[--destroy-pulumi-residue | --allow-pulumi-residue]`
and rejects both-together at parse time with "Invalid option" exit 1; new
`awsTeardownPolicyFromFlags :: Bool -> Bool -> Either String PulumiResiduePolicy` pure
helper for unit tests); `test/unit/Main.hs` (24 new tests across four blocks: Sprint 7.7
residue lifecycle partition, Sprint 7.7 applyAwsTeardown residue policy Scenarios E/F/G/H/I,
Sprint 7.7 DestroyPulumiResidueFirst dispatch plan Scenarios J/K/L,
Sprint 7.7 promptAdminCredentials UX sessionTokenPromptShape,
Sprint 7.7 awsTeardownPolicyFromFlags mutual exclusion).
**Docs to update**:
`DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md`,
`documents/engineering/aws_integration_environment_doctrine.md`,
`documents/engineering/aws_admin_credentials.md`,
`documents/engineering/aws_account_setup_guide.md`,
`documents/engineering/cli_command_surface.md`

### Objective

Close four related defects observed in the May 19, 2026 diagnostic session, all rooted in
`src/Prodbox/Aws.hs` and all touching the operator-facing teardown contract:

1. **Harness teardown bypasses the long-lived-residue refusal.** Sprint `7.6` closed the
   refuse-path for the **operator-driven** `prodbox aws teardown` invocation, but the
   **test-harness internal** path in `src/Prodbox/Aws.hs::runAwsIamHarnessTeardown` (and the
   preflight call in `runAwsIamHarnessSetup`) passes `awsTeardownAllowPulumiResidue = True`
   unconditionally, which bypasses the same refuse-path it was designed to enforce. Result:
   on May 18 the operator closed Sprint `8.1` by provisioning `aws-ses`; on May 19 a
   `prodbox test integration aws-iam` run cleared operational `aws.*` from
   `prodbox-config.dhall` even though `aws-ses` was alive, stranding the `aws-ses` Pulumi
   stack from the supported destroy surface until the operator reran `prodbox aws setup`.
2. **Admin-credential prompt is misleading.** `promptAdminCredentials` (around lines 738–757)
   asks for four fields sequentially, with the "optional" session-token hint buried in a
   parenthetical. Operators using long-lived `AKIA…` IAM user keys can't tell whether they
   should fill the session-token field; operators using STS-derived `ASIA…` keys may skip it
   thinking "optional" means "always skippable", which then breaks every subsequent AWS API
   call with `InvalidClientTokenId`. The prompt label still says "Elevated AWS" rather than
   the doctrine-canonical "temporary admin"; the residual "Elevated AWS …" prompt strings
   are already on the legacy-tracking-for-deletion ledger.
3. **`aws teardown` prompts for credentials before knowing whether they are needed.** The
   current control flow prompts for the temporary admin credential first and only then
   checks for Pulumi residue, which is wasted operator effort when the residue check refuses
   immediately afterward. The residue check is file-based (`doesFileExist
   .prodbox-state/<stack>/stack-snapshot.json`) and needs no credentials — it can and should
   run before the prompt.
4. **`aws teardown` has no path to clean up Pulumi residue automatically.** Today
   `aws teardown` either refuses (default) or proceeds while stranding Pulumi resources
   (`--allow-pulumi-residue`, operator-acknowledged orphan). There is no third option:
   "destroy the Pulumi stacks for me, then continue with the IAM teardown." Adding
   `--destroy-pulumi-residue` (mutually exclusive with `--allow-pulumi-residue`) makes the
   common cleanup case one command instead of N.

### Deliverables

- **New `PulumiResiduePolicy` ADT** in `src/Prodbox/Aws.hs` with four constructors:
  `RefuseOnAnyResidue` (default, operator-driven), `DestroyPulumiResidueFirst`
  (operator-driven via `--destroy-pulumi-residue`), `AcceptOrphanResidue` (operator-driven
  via `--allow-pulumi-residue`), `BypassPerRunResidueOnly` (harness-internal only; never
  CLI-settable). Replaces the existing `awsTeardownAllowPulumiResidue :: Bool` field on
  `AwsTeardownInput` and `AwsTeardownFlags`.
- **Per-run vs long-lived partition** of `checkPulumiResidueBeforeTeardown` results.
  Partition keys must match `DEVELOPMENT_PLAN/substrates.md → Resource Lifecycle Classes`
  verbatim:
  - Per-run: `aws-eks`, `aws-eks-subzone`, `aws-test`
  - Long-lived: `aws-ses`
  Bypass policy matrix:

  | Policy | Per-run live | Long-lived live | Action |
  |---|---|---|---|
  | `RefuseOnAnyResidue` | any | any | Refuse, full list |
  | `BypassPerRunResidueOnly` | any | none | Proceed |
  | `BypassPerRunResidueOnly` | any | any | Refuse, long-lived list only |
  | `AcceptOrphanResidue` | any | any | Proceed silently |
  | `DestroyPulumiResidueFirst` | any | any | Dispatch `pulumi <stack>-destroy --yes` in canonical order, then proceed |

- **`runAwsIamHarnessSetup` and `runAwsIamHarnessTeardown`** use
  `awsTeardownResiduePolicy = BypassPerRunResidueOnly` (was: unconditional `True`). The
  harness now refuses on `aws-ses` residue exactly the same way the operator-driven path
  does.
- **`interactiveAwsTeardownInput` refactor** (the Defect 3 + 4 fix): run the file-based
  residue check first, then decide whether to prompt. Return shape becomes `IO (Either
  RefusalMessage (Maybe AwsTeardownInput))`:
  - `Left msg` — residue refused (caller exits non-zero, prints message). No prompt.
  - `Right Nothing` — residue empty AND operational `aws.*` empty: nothing to do (caller
    exits 0, prints "AWS teardown: no operational `aws.*` configured and no Pulumi residue.
    Nothing to do."). No prompt.
  - `Right (Just input)` — proceed to `applyAwsTeardown`. Prompt fires.
  Pre-prompt summary for the `DestroyPulumiResidueFirst` case: "Will run aws-subzone-destroy
  --yes, then eks-destroy, then test-destroy, then aws-ses-destroy --yes" (only the stacks
  actually live) plus the long-lived warning if `aws-ses` is in the plan.
- **`promptAdminCredentials` refactor** (the Defect 2 fix): extract a pure helper
  `sessionTokenPromptShape :: Text -> SessionTokenPromptShape` that returns `SkipPrompt`
  for `AKIA…` prefixes, `PromptRequiredHidden` for `ASIA…`, and `PromptOptionalWithHint`
  for any other (rare: `AGPA`, `AROA`, etc., or empty). Use it to conditionally invoke the
  session-token prompt. Rename all four user-facing strings from "Elevated AWS …" /
  "elevated operations" to "Temporary admin AWS …" / "admin operations". Update
  `showAdminCredentialsGuidance` body to explain both `AKIA` and `ASIA` credential shapes
  in plain language.
- **`awsTeardownFlagsParser` mutual exclusion**: parses `--allow-pulumi-residue` and
  `--destroy-pulumi-residue` as boolean flags but rejects them together at parse time with
  a structured error citing the contradiction.
- **`applyAwsTeardown` test seam**: accept an injected destroy-dispatcher function (default
  = real `runNativeCliCommandForExitCode` subprocess wrapper) so unit tests can capture the
  ordered list of `pulumi <stack>-destroy --yes` commands the `DestroyPulumiResidueFirst`
  branch would have run. Mirrors the existing test-hook contract per Sprint `2.13`.

### Validation

1. `prodbox check-code` exit 0 ✅.
2. `prodbox test unit` exit 0 ✅ (378/378, up from 354 — 24 new Sprint 7.7 tests across the
   residue-policy partition, applyAwsTeardown scenarios E/F/G/H/I,
   DestroyPulumiResidueFirst dispatch plan scenarios J/K/L,
   `sessionTokenPromptShape` UX, and `awsTeardownPolicyFromFlags` mutual exclusion).
3. `prodbox lint docs` exit 0 ✅.
4. `prodbox docs check` exit 0 ✅.
5. `grep -nE "Elevated AWS|elevated operations" src/Prodbox/Aws.hs` returns no hits ✅.
6. CLI smoke verified live this session: `prodbox aws teardown --help` shows
   `[--destroy-pulumi-residue | --allow-pulumi-residue]` mutual-exclusion bracket.
   `prodbox aws teardown --allow-pulumi-residue --destroy-pulumi-residue` exits 1 with
   "Invalid option `--destroy-pulumi-residue'" before any further work.
7. Manual operator smokes (operator-driven, deferred):
   - `prodbox test integration aws-iam` with `aws-ses` live → suite exits non-zero with the
     `aws-ses-destroy --yes` actionable message; dedicated `prodbox` IAM user **not**
     deleted; `aws.*` **not** cleared.
   - `prodbox aws teardown` with no Pulumi residue and `aws.*` empty → prints "Nothing to
     do." and exits 0 **without** prompting for credentials.
   - `prodbox aws teardown` with `aws-ses` live and `aws.*` empty → refuses immediately
     with the `aws-ses-destroy --yes` hint **before** prompting for any credentials.
   - `prodbox aws teardown --destroy-pulumi-residue` with `aws-ses` live → prints SES
     reverify + S3 cooldown warning, runs `pulumi aws-ses-destroy --yes`, then IAM
     teardown, then clears `aws.*`.
   - `prodbox aws teardown --allow-pulumi-residue --destroy-pulumi-residue` → parser-level
     error citing mutual exclusion, exits non-zero before any other work.
   - `prodbox aws setup`: pasting `AKIA…` skips the session-token prompt; pasting `ASIA…`
     (e.g. from `aws sts get-session-token`) fires the session-token prompt as required
     hidden input. The prompt label says "Temporary admin …", not "Elevated".

### Remaining Work

None on the sprint-owned surface. The four manual operator smokes listed under § Validation
step `7` remain as deferred live regressions — they exercise paths (mutual-exclusion error,
nothing-to-do exit, `--destroy-pulumi-residue` with `aws-ses` live) that the unit suite
covers via pure helpers and structural assertions but cannot exercise end-to-end without
real AWS credentials in the operator's hands.

## Sprint 7.8: Operational-Credential Lifecycle via the Managed-Resource Registry ✅

**Status**: Done. Live closure 2026-06-01 via `prodbox test all` retry 21:
the postflight reported `USER_DELETED=true`, `DELETED_ACCESS_KEYS=1`, and
`POST_RUN_OPERATIONAL_CONFIG_CLEARED=true` — proving the two `Operational`
resources are reconciled through `reconcileAbsent` end-to-end (operational
`prodbox` IAM user deleted, `aws.*` config block cleared). Operational-coverage
core landed on the code-owned surface 2026-05-28. The broader `PerRun` ∪
`Operational` merge of the teardown path remains tracked as a separate
follow-on (the per-run Pulumi residue gating in `applyAwsTeardown` is unchanged
by design).
**Unblocked by**: Sprint 4.20, Sprint 4.21 (the registry + `reconcileAbsent` now exist
and are reused here)
**Implementation**: `src/Prodbox/Aws.hs`, `src/Prodbox/Lifecycle/ResourceRegistry.hs`
**Docs to update**: `documents/engineering/aws_integration_environment_doctrine.md`,
`documents/engineering/lifecycle_reconciliation_doctrine.md` (§3.1 cross-ref)

### Why Phase 7 reopened

Phase 7 owns the `prodbox aws setup` / `aws teardown` command surface and the operational
`prodbox` IAM-user lifecycle. The managed-resource-registry doctrine
([lifecycle_reconciliation_doctrine.md § 3.1](../documents/engineering/lifecycle_reconciliation_doctrine.md),
scheduled in Phase 4 Sprints 4.20–4.22) re-expresses teardown as a uniform reconciliation over
a typed registry. Because that changes how this phase's own commands behave, Phase 7 reopens
for this one sprint to adopt the registry. Phases 5 and 6, and the rest of Phase 7's owned
surfaces (Sprints 7.1–7.7, and the Sprint 7.5 AWS-substrate parity work), remain closed/active
on their own surfaces and are not contradicted — `aws setup`/`teardown` keep their behavior;
they are simply expressed through the registry rather than as a bespoke imperative sequence.
This is the documented motivation for the in-session leak incident: the operational IAM user
and operational `aws.*` config block were created by `aws setup` but had no registered
discover/destroy, so an interrupted run leaked both undetected.

### Objective

Register the two `Operational`-class resources and reconcile them through the registry, closing
the coverage half of the IAM blind spot
([lifecycle_reconciliation_doctrine.md § 6a](../documents/engineering/lifecycle_reconciliation_doctrine.md)).

### Deliverables

Landed (operational-coverage core):

- The operational `prodbox` IAM user and the operational `aws.*` config block are registered
  `Operational` `ManagedResource` entries defined in `src/Prodbox/Aws.hs`
  (`operationalManagedResources`), reusing the existing
  `deleteExistingOperationalKeys` / `deleteUserPolicyIfPresent` /
  `deleteOperationalUserIfPresent` IAM-delete paths and the factored-out
  `clearOperationalAwsConfig` for the `aws.*` clear. The entries are defined in `Aws.hs`
  (not `ResourceRegistry.hs`) to keep `ResourceRegistry` from importing `Aws` — it reuses the
  shared `ManagedResource` type + `reconcileAbsent`.
- Discover is pure-mapped from existing probes: `operationalIamUserResidueFromExists`
  (over `operationalIamUserExists`) and `operationalAwsConfigResidueFromKey` (over the
  configured `aws.access_key_id`), assembled by the IO `discoverOperationalResidue`.
- `prodbox aws teardown` destroys the operational resources via `reconcileAbsent` over the
  `Operational` pairs — idempotent on re-run (already-absent → no-op), and **fails closed** on
  any `Operational`-class `ResidueUnreachable` (e.g. AWS IAM unobservable): a separate gate in
  `runTeardown` refuses with a named-resource message rather than letting `reconcileAbsent`'s
  cascade graceful-degradation silently skip an unreachable operational resource. The
  read-only `listOperationalAccessKeyIds` records the pre-reconcile keys so
  `IamTeardownResult` keeps reporting `DELETED_ACCESS_KEYS` / `USER_DELETED`.

Deferred to a tracked follow-on (NOT this sprint):

- The broader re-expression of `prodbox aws teardown` as `reconcileAbsent` over the
  **`PerRun` ∪ `Operational`** subset. The existing `PulumiResiduePolicy` branching and
  per-run residue handling in `applyAwsTeardown` are left byte-identical; only the operational
  half is registry-driven.
- `prodbox aws setup` recording its created resources through the registry.

### Validation

Done (fast gates, no live AWS):

- `prodbox check-code` → exit 0 (warning-clean build + lint + the Sprint 4.22 totality scan).
- `prodbox test unit` → 594 examples pass (was 585; +9 in the new
  `Sprint 7.8 operational-resource registry` group exercising the pure residue-mappers and the
  two-entry `operationalManagedResources` table, asserting the names match
  `resourceNamesOfClass Operational`).
- `prodbox test integration cli` / `env` → 30/30 each. The fake AWS CLI learned an
  `iam get-user` case so teardown's new discover probe observes the operational user's
  presence/absence accurately (instead of mapping the unhandled command to `Unreachable` and
  refusing); re-running `aws teardown` converges and stale `aws.*` creds reconcile to empty.

Live roll-up: the June 5, 2026 `prodbox test all --substrate aws` run proved the operational
postflight on a real account again: after the Phase 7-owned validations and lifecycle passed,
the harness destroyed the per-run stacks and cleared operational `aws.*` / deleted the
operational IAM user before surfacing the Sprint `8.6` ordering failure.

### Remaining Work

- The `PerRun` ∪ `Operational` teardown merge (tracked follow-on; per-run residue gating
  unchanged by this sprint).

**2026-05-30 — reaffirmation.** `prodbox test all` run #6 on the home substrate exercised the
registry-driven `aws teardown` cleanly: the postflight reconciled both `Operational`-class
entries (the operational `prodbox` IAM user and the operational `aws.*` config block) to absent
without incident; post-run AWS state verified clean (operational `aws.*` empty, only the retained
admin-managed IAM users `prodbox-admin-temp` and `prodbox-ses-smtp` remain).

## Sprint 7.9: Harness Postflight Teardown No Longer Gates on Admin-Managed `aws-ses` ✅

**Status**: Done on the code-owned surface (2026-05-29)
**Implementation**: `src/Prodbox/Aws.hs` (`runAwsIamHarnessTeardown` postflight switched from
`BypassPerRunResidueOnly` to `BypassAllResidueForHarnessRefresh`, with the post-4.10 rationale
in the comment; new pure SSoT helper `harnessPostflightResiduePolicy` exported so the choice is
unit-testable without IO; the stale "destroy aws-ses first" refusal message replaced with the
accurate Sprint 7.8 fail-closed-gate message); `test/unit/Main.hs` (new
`Sprint 7.9 harness postflight no longer gates on admin-managed aws-ses` describe block);
`DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md` (`BypassPerRunResidueOnly` now
harness-internal-but-unused).
**Docs to update**: `documents/engineering/aws_admin_credentials.md` (§4.1, §5),
`documents/engineering/aws_integration_environment_doctrine.md`,
`DEVELOPMENT_PLAN/system-components.md`, `DEVELOPMENT_PLAN/00-overview.md`,
`DEVELOPMENT_PLAN/README.md`, `DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md`.

### Objective

Close an operational-user stranding bug: every `prodbox test all` run that has the long-lived
`aws-ses` stack alive (its retained-by-design steady state) ended with the harness postflight
**refusing** to clear operational `aws.*`, stranding the freshly-created operational `prodbox`
IAM user — the opposite of the leak-free goal.

### History (why the refusal was correct, then went stale)

1. **Sprint 7.7 (May 19, 2026)** introduced the `aws-ses` refusal (`BypassPerRunResidueOnly`).
   At that time — *before* Sprint 4.10 — the `aws-ses` stack was managed with **operational**
   `aws.*` creds, so clearing `aws.*` genuinely stranded `aws-ses` from its destroy surface.
   The refusal was correct then.
2. **Sprint 4.10 (May 21, 2026)** moved `aws-ses` to **admin** creds
   (`aws_admin_for_test_simulation.*`) and the then-current long-lived S3 backend.
   Sprint `7.14` keeps main `aws-ses` operations admin-credentialed but runs them through
   `pulumiSesProviderBaseEnv` + `Prodbox.Pulumi.EncryptedBackend`; `pulumiSesAdminBaseEnv` remains
   only as the optional first-touch import/delete source for old long-lived S3 checkpoints. Clearing
   operational `aws.*` can no longer strand `aws-ses`. (Sprint `7.16` supersedes the
   stored-admin-in-`prodbox-config.dhall` model that this dated note assumes: real `aws-ses` ops
   acquire the ephemeral elevated credential through the interactive `SecretRef.Prompt`, and the
   harness simulates that prompt from the `test-secrets.dhall` fixture — there is no production
   config-backed admin path.)
3. **Sprint 7.5.c.v.c (May 20, 2026)** fixed the *preflight* `runAwsIamHarnessSetup` the same
   way (switched it to the new `BypassAllResidueForHarnessRefresh` constructor) but deliberately
   left the *postflight* `runAwsIamHarnessTeardown` on `BypassPerRunResidueOnly` "because at
   end-of-run the operator may legitimately need `aws.*` preserved to destroy `aws-ses`" — a
   pre-4.10 premise that is now false.
4. **Sprint 7.9 (this sprint)** corrects the postflight: it is the same admin-managed `aws-ses`,
   so clearing operational `aws.*` cannot strand it; per-run stacks are destroyed separately by
   `awsPostflightDestroyActions` before teardown. The postflight bypasses all residue and clears
   `aws.*` unconditionally, matching the preflight.

This **supersedes** the Sprint 7.5.c.v.c "postflight keeps `BypassPerRunResidueOnly`" decision
and the Sprint 7.7 postflight refusal on long-lived `aws-ses` residue.

### The fix

One-line policy swap in `runAwsIamHarnessTeardown`:
`awsTeardownResiduePolicy = BypassPerRunResidueOnly` →
`awsTeardownResiduePolicy = BypassAllResidueForHarnessRefresh` (the constructor already exists
with the correct `-> runTeardown` branch in `applyAwsTeardown`). The `BypassPerRunResidueOnly`
constructor and its `applyAwsTeardown` case branch are retained as a valid ADT member (it still
refuses on long-lived residue) but have no production caller after this sprint; it is tracked in
[legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md) `Pending Removal`. The
preflight `runAwsIamHarnessSetup` is unchanged (already `BypassAllResidueForHarnessRefresh`).

### Deferred follow-on (NOT addressed here)

The lost `aws-ses` Pulumi state (the long-lived S3 backend bucket `prodbox-pulumi-state-long-lived`
missing, leaving `aws-ses` Pulumi-unmanageable until re-imported / re-provisioned) is a
**separate** issue. Sprint 7.9 only stops the operational-user stranding; it does not address the
lost-`aws-ses`-state problem. Later Phase `8` follow-up work closes that separate issue by having
`prodbox pulumi aws-ses-resources` recreate the long-lived backend state, import the retained
capture bucket / SMTP IAM user / SES receipt resources, rotate stale SMTP access keys, and
reconcile overwrite-tolerant Route 53 records.

### Validation

Fast gates (no live AWS):

- `prodbox check-code` → exit 0.
- `prodbox test unit` → all pass (new `Sprint 7.9` describe block added).
- `prodbox test integration cli` / `env` → exit 0 each.
- `prodbox docs check` / `prodbox lint docs` → exit 0 (governed docs reconciled).

Not run here: live `prodbox test all --substrate aws` roll-up (confirms an `aws-ses`-live run
ends with operational `aws.*` cleared and the operational `prodbox` IAM user deleted).

### Remaining Work

- Live `prodbox test all --substrate aws` exercise confirming the postflight clears operational
  `aws.*` while `aws-ses` is live.
- Eventual removal of the now-unused `BypassPerRunResidueOnly` constructor (tracked in
  `legacy-tracking-for-deletion.md`).

**2026-05-30 — reaffirmation.** `prodbox test all` run #6 on the home substrate completed
postflight without the stale `aws-ses` refusal: the postflight cleared operational `aws.*` and
deleted the operational `prodbox` IAM user cleanly while the long-lived `aws-ses` stack was
retained as-is (untouched, by design).

## Sprint 7.10: Harness Postflight Preserves Operational Creds When the Per-Run Auto-Destroy Fails ✅

**Status**: Done (2026-05-29), fast-gate-validated
**Implementation**: `src/Prodbox/TestRunner.hs`
(`runWithAwsHarnessCleanup` now runs the operational-credential teardown
`runManagedAwsHarnessTeardown` **only when the per-run destroy succeeded**, gated by the new
pure helper `clearOperationalCredsAfterPostflight :: ExitCode -> Bool` — `True` iff
`ExitSuccess`, exported for unit testing; on a per-run destroy failure the teardown is held, the
operational `aws.*` + operational `prodbox` IAM user are preserved, and a diagnostic explains
the retry path); `test/unit/Main.hs` (new
`Sprint 7.10 harness preserves creds on per-run destroy failure` describe block).
**Docs to update**: `DEVELOPMENT_PLAN/README.md`, `DEVELOPMENT_PLAN/system-components.md`,
`DEVELOPMENT_PLAN/00-overview.md`,
`documents/engineering/lifecycle_reconciliation_doctrine.md`.

### Objective

Close a leak amplifier observed on the May 28/29 live `prodbox test all` run: the per-run
`aws-eks-test` Pulumi destroy failed with `DependencyViolation` (orphan ENIs lagging async
cleanup — the root cause of which Sprint 4.23 addresses), but the harness postflight then went
on to clear operational `aws.*` and delete the operational `prodbox` IAM user **anyway**,
stranding the orphaned per-run stacks without the operational credentials needed to destroy them
on retry.

### The fix

`runWithAwsHarnessCleanup` already runs the per-run Pulumi destroys
(`awsPostflightDestroyActions`) on every exit path — success, failure, and async exception
(Ctrl-C) — per Sprint 7.6, and that stays. What changes is the **operational-credential
teardown**: it now runs only when `clearOperationalCredsAfterPostflight destroyExit` is `True`
(i.e. the per-run destroy succeeded). On `ExitFailure`, the teardown is skipped, the operational
`aws.*` + operational `prodbox` user are preserved, and a diagnostic (via `writeDiagnosticLine`)
names the recovery path: resolve the destroy failure (e.g. wait out / clean up the orphan ENIs
behind the `DependencyViolation`), then `prodbox pulumi <stack>-destroy --yes` for each remaining
per-run stack, then `prodbox aws teardown`. The change applies on **both** the normal (`Right`)
and async-exception (`Left exc`) paths. A per-run destroy failure is still surfaced as a non-zero
exit via `preferEarlierFailure` composition.

### Relationship to Sprint 7.9

This is the per-run analog of Sprint 7.9. Sprint 7.9 said "don't **block** the teardown on
admin-managed `aws-ses` residue" (clearing operational creds cannot strand the admin-credential
`aws-ses` stack). Sprint 7.10 says "**DO hold** the teardown when the per-run auto-destroy —
which *does* need operational creds — failed." The two are complementary: 7.9 stops the teardown
from refusing when it safely could proceed; 7.10 stops the teardown from proceeding when doing so
would strand operational-credential-owned orphans.

### Validation

Fast gates (no live AWS):

- `prodbox check-code` → exit 0.
- `prodbox test unit` → all pass (new `Sprint 7.10` describe block, 2 new tests).
- `prodbox test integration cli` / `env` → exit 0 each.
- `prodbox docs check` / `prodbox lint docs` → exit 0.

The pure decision (`clearOperationalCredsAfterPostflight`) is fully unit-tested; the IO wiring in
`runWithAwsHarnessCleanup` is thin (one gated call). No live AWS required.

## Sprint 7.11: Single ZeroSSL ACME ClusterIssuer and Substrate-Scoped Long-Lived Cert Retention Store ✅

**Status**: Done (2026-06-07 on the code-owned surface)
**Implementation**: `src/Prodbox/CLI/Rke2.hs` (`acmeClusterIssuerSpec` + factored
`acmeRoute53Solver`; `zerosslAccountKeySecretName` constant; `acmeRuntimeManifestWith` renders
the single ZeroSSL issuer; `ensureAcmeRuntime` waits for it),
`src/Prodbox/Lib/AwsSubstratePlatform.hs` (`ensureAwsSubstrateAcmeRuntime` waits for the
issuer), `src/Prodbox/PublicEdge.hs` (`publicEdgeClusterIssuerName` constant +
`publicEdgeTlsRetentionKey` substrate key scheme),
`src/Prodbox/Infra/LongLivedPulumiBackend.hs` (`putLongLivedObject` /
`getLongLivedObject` / `isLongLivedNoSuchKeyMessage` retention access path)
**Docs to update**: `documents/engineering/acme_provider_guide.md`,
`documents/engineering/envoy_gateway_edge_doctrine.md`,
`documents/engineering/config_doctrine.md`, `DEVELOPMENT_PLAN/substrates.md`

### Objective

Render one cert-manager `ClusterIssuer` (`zerossl-dns01`, built from `acme.server`) with a
factored DNS-01 Route 53 solver and the ZeroSSL external account binding, and add the
substrate-scoped long-lived cert retention store. The retained cert material is stored in the
long-lived `pulumi_state_backend` S3 bucket under a substrate-scoped key
(`public-edge-tls/<substrate>/<fqdn>`), reusing the `LongLivedPulumiBackend` access path, so
rebuild cycles restore the certificate rather than re-order it (and never consume ZeroSSL
issuance quota). This is the substrate-aware extension of the Sprint 7.5.b cert-manager DNS-01
ClusterIssuer rendering; the substrate-equivalence doctrine (home + AWS both ZeroSSL) is
preserved.

> **Supersession note.** This sprint originally rendered an earlier multi-issuer model with a
> separate test issuer and a provider-selection mechanism. That model was reverted to a single
> ZeroSSL issuer when ZeroSSL became the sole supported ACME provider (2026-06-07) — ZeroSSL has
> no separate test endpoint, and the S3 retain-and-restore of the issued certificate (below)
> already covers rebuild churn. The separate test issuer, its config field, its default constant,
> and the provider-selection machinery are removed.

### Deliverables

- One ZeroSSL ACME `ClusterIssuer` (`zerossl-dns01`) with a factored DNS-01 Route 53 solver
  and the required ZeroSSL external account binding.
- The issuer carries its own `privateKeySecretRef` account key (`zerossl-account-key`).
- A substrate-scoped S3 retention key scheme stores the public-edge cert so rebuilds restore
  rather than re-order it.
- The public-edge cert is added to the [substrates.md](substrates.md) Resource
  Lifecycle Classes (LongLived). This row is rendered by the GENERATED table driven by
  `resourceLifecycleClasses` (landed under Phase 4 Sprint 4.24), so it appears after
  `prodbox docs generate`, not via hand-edit.

### Validation

Closure gates (passed 2026-06-07):

1. `./.build/prodbox check-code` → exit `0`.
2. `./.build/prodbox test unit` → `690/690` (the
   `ZeroSSL ACME ClusterIssuer + cert retention key scheme` describe block covers: the issuer
   rendering `acme.server` + the `zerossl-account-key` account key; the DNS-01 Route 53 solver
   secret + hosted zone; the ZeroSSL external account binding when configured; the single issuer
   rendered by `acmeRuntimeManifestWith`; the `zerossl-dns01` issuer name constant; and the
   substrate-scoped `publicEdgeTlsRetentionKey`).
3. `./.build/prodbox test integration cli` / `./.build/prodbox test integration env` → the
   ZeroSSL `acme` fixtures decode in every fixture (the `aws-iam`, `config setup`,
   ZeroSSL-EAB ClusterIssuer-reconcile, and masked-settings paths all pass). The only two
   failures in this environment (`CliSuite.hs:256`/`:376`, `charts deploy vscode`
   fake-environment flows) reproduce identically on the pre-Sprint-7.11 tree and are
   unrelated.
4. `./.build/prodbox docs check` / `./.build/prodbox lint docs` → exit `0`.

### Remaining Work

The live single-issuer + S3-retention behavior is exercised under Phase 8 Sprint 8.8 (home gate
first, then AWS parity, plus the production round-trip). The S3 cert-retention `put`/`get`
access path landed here is consumed by the chart-platform restore-before-issue refactor in
Sprint `8.7`.

## Sprint 7.12: Substrate Equivalence as a Structural Invariant ✅

**Status**: Done (2026-06-09). A new `EnvoyGatewayRelease`/`envoyGatewayRelease` SSoT in
`ContainerImage.hs` pins the Envoy Gateway chart version + control-plane image + data-plane image
together (chart `v1.7.2` / control `v1.7.2` / data `distroless-v1.37.0`, the proven home pairing) and
feeds all three sites on BOTH substrates — eliminating the EG-`1.4.4`/Envoy-`1.37` skew (audit C79)
by construction (the AWS install's hardcoded `v1.4.4` chart + missing controller override are gone).
The same SSoT treatment was applied to the cert-manager / Percona-operator / MinIO chart versions.
`checkSubstrateImagePinning` (wired into `runDoctrineAlignmentCheck`, proven to fire) forbids
per-substrate re-pinning of a SHARED component's chart-version/image while exempting the genuinely
substrate-specific lower layer (AWS LB Controller, MetalLB, FRR, containerd-mirror). A shared
`[PlatformComponent]` inventory (13 components) is declared once and consumed by both installers,
with a coverage test asserting neither omits a component (NOT a unified step DAG). The stale "no
Harbor on EKS" prose was corrected across `AwsSubstratePlatform.hs` + the doctrine docs +
`substrates.md` (Harbor + MinIO + Percona run on both substrates; the AWS Harbor is the EKS-side
Harbor + node-local registry proxy). Validation green: `check-code` 0, `test unit` 0, `integration
cli` 0, `lint docs` 0, `docs check` 0. The live `prodbox test all --substrate aws` re-validation is
operator-driven.
**Implementation**: `src/Prodbox/ContainerImage.hs` (recommended — new SSoT module for the single
Envoy release value), `src/Prodbox/Lib/AwsSubstratePlatform.hs`, `src/Prodbox/CLI/Rke2.hs`,
`src/Prodbox/Lib/ChartPlatform.hs`, `charts/`, `src/Prodbox/CheckCode.hs` (the per-substrate
re-pin lint), `test/unit/Main.hs`
**Docs to update**: `documents/engineering/helm_chart_platform_doctrine.md`,
`documents/engineering/envoy_gateway_edge_doctrine.md`,
`documents/engineering/aws_integration_environment_doctrine.md`,
`DEVELOPMENT_PLAN/substrates.md`

### Why Phase 7 reopened

The substrate-equivalence contract ("the home local substrate and the AWS substrate stand up the
same set of services") currently lives only as prose in `CLAUDE.md` and
[substrates.md](substrates.md). Nothing structural enforces it, so the worktree drifted: the home
substrate and the AWS substrate independently pin Envoy Gateway / Envoy versions (the
EG-`1.4.4` chart shipped by Sprint `7.5.b.ii.β` against a data-plane Envoy `1.37` image — a skew
that can only be caught by reading two files in two modules), and the doctrine still carries a
stale "no Harbor on EKS" reading that the Sprint `7.5.b.ii` Harbor-mirrored chart-platform install
already contradicts. Phase 7 owns the AWS-substrate platform install paths, so making equivalence a
compiler/lint/test-enforced invariant — instead of trusting prose — reopens this phase for one
sprint. Per [development_plan_standards.md → M. Substrate coverage and independence (no fallback)](development_plan_standards.md#substrate-coverage-and-independence-no-fallback)
the two installers must remain behaviorally equivalent without per-substrate special-casing.

### Objective

Replace the prose substrate-equivalence contract with three structural enforcers — one pinned Envoy
release value shared across chart + control plane + data plane, a lint forbidding per-substrate
chart-version / image re-pinning, and a shared `[PlatformComponent]` inventory with a coverage test
that both installers must satisfy — and correct the stale "no Harbor on EKS" prose. The two
installers stay as separate code paths (home: MetalLB + the in-cluster Harbor NodePort pattern;
AWS: AWS Load Balancer Controller + the EKS-side Harbor + node-local registry proxy); only the
*component set* is asserted equal, **not** unified into one step DAG.

### Deliverables

- A new `Prodbox.ContainerImage` SSoT exposes one Envoy Gateway release value (e.g.
  `envoyGatewayRelease`) consumed by all three pinning sites together: the Envoy Gateway Helm chart
  version, the control-plane install (`ensureAwsSubstrateEnvoyGatewayRuntime` and the home
  equivalent), and the data-plane proxy image. The EG-`1.4.4` / Envoy-`1.37` skew is eliminated by
  construction — there is no second place to change a version independently.
- A `checkSubstrateImagePinning` (or equivalently-named) lint in `src/Prodbox/CheckCode.hs`
  **forbids per-substrate chart-version or image re-pinning** — any chart version / image reference
  bound on a per-substrate branch (i.e. keyed off `Substrate`/`SubstrateAws`/`SubstrateHomeLocal`)
  is a violation; the single pinned value from `Prodbox.ContainerImage` is the only sanctioned
  source. Wired into `prodbox check-code`.
- A shared `[PlatformComponent]` inventory (`gateway`, `keycloak`, `keycloak-postgres`, `vscode`,
  `api`, `redis`, `websocket`, plus MinIO, Harbor, the Percona PostgreSQL operator, Envoy Gateway,
  cert-manager, ZeroSSL DNS01) declared once and consumed by both the home install path
  (`Prodbox.CLI.Rke2` / `Prodbox.Lib.ChartPlatform`) and the AWS install path
  (`Prodbox.Lib.AwsSubstratePlatform`).
- A **coverage test** (not a unified step DAG) in `test/unit/Main.hs` asserting that both
  substrate installers cover every entry in the shared `[PlatformComponent]` inventory. The two
  installers keep their distinct lower-layer implementations (MetalLB vs AWS LB Controller, parent
  zone vs delegated subzone); the test asserts only that neither installer omits a component.
- The stale "no Harbor on EKS" prose is corrected across the doctrine docs and [substrates.md](substrates.md)
  to state that Harbor + MinIO + the Percona operator are installed on **both** substrates (the AWS
  substrate's Harbor is the EKS-side Harbor + node-local registry proxy that makes
  `127.0.0.1:30080/prodbox/...` resolve on EKS, mirroring the home NodePort-on-`127.0.0.1` pattern).

### Validation

1. `prodbox check-code` (exercises the new per-substrate re-pin lint).
2. `prodbox test unit` (the `[PlatformComponent]` coverage test asserts both installers cover the
   shared inventory).
3. `prodbox docs check` / `prodbox lint docs` (corrected "no Harbor on EKS" prose reconciled).
4. Live re-validation: `prodbox test all --substrate aws` proves the single Envoy release value
   stands up Envoy Gateway on EKS with no chart/data-plane skew and the canonical suite stays green.

### Remaining Work

None — closed 2026-06-09. The `ContainerImage` Envoy/cert-manager/Percona/MinIO release SSoT, the
`checkSubstrateImagePinning` lint, the shared `[PlatformComponent]` inventory + coverage test, and
the "no Harbor on EKS" prose corrections all landed. The live `prodbox test all --substrate aws`
re-validation (single Envoy release with no skew) is operator-driven.

## Sprint 7.13: DNS-01-Honest Issuer Rename and Public-Edge Route-Ownership Correction ✅

**Status**: Done (2026-06-09). The public-edge ACME issuer was renamed to the DNS-01-honest
`zerossl-dns01` (from its historical HTTP-01-spelled name) from one SSoT constant
(`publicEdgeClusterIssuerName` in
`PublicEdge.hs`) flowing to all consumers — `acmeClusterIssuerSpec`/`acmeRuntimeManifestWith` + the
issuer-wait (`Rke2.hs`), `ensureAwsSubstrateAcmeRuntime` (`AwsSubstratePlatform.hs`), the
`ChartPlatform.hs` issuer references, and `charts/keycloak/values.yaml` + `charts/vscode/values.yaml`
— with all ~41 doc/test sites updated; the old HTTP-01-spelled name now appears nowhere in code,
charts, docs, tests, or goldens. The doctrine reattributes the shared Gateway / listener-cert / redirect / `/auth` route
to the `keycloak` chart (verified against `charts/keycloak/templates/gateway.yaml`). `PublicEdge.hs`
no longer reads `PRODBOX_AWS_SUBSTRATE_HOSTED_ZONE_ID` — `resolveSubstrateHostedZoneId` sources the
hosted-zone id from settings (`aws_substrate.hosted_zone_id`) with the live `aws-eks-subzone` Pulumi
output as fallback; `withSubstrateKubectlEnvironment` was relocated to a new
`Prodbox.Infra.SubstrateKubectl` module (avoiding an import cycle) so `PublicEdge.hs` is env-I/O-free,
and `PublicEdge.hs` was added to `checkEnvVarConfigReads.scopedPaths`. Validation green: `check-code`
0, `test unit` 821/821, `integration cli` 35/35, `integration env` 35/35, `lint docs` 0, `docs check`
0. The live issuer-rename-on-rebuild (the S3 cert restores under the new name — the retention key is
substrate+FQDN-keyed) is operator-driven.
**Implementation**: `src/Prodbox/PublicEdge.hs` (one SSoT issuer-name constant; the
`PRODBOX_AWS_SUBSTRATE_HOSTED_ZONE_ID` env-read fix), `src/Prodbox/CLI/Rke2.hs`
(`acmeClusterIssuerSpec` rename consumer), `charts/keycloak/values.yaml`,
`charts/gateway/values.yaml` (the two chart `values.yaml` issuer references),
`src/Prodbox/CheckCode.hs` (extend `checkEnvVarConfigReads`), `test/unit/Main.hs`,
`test/golden/`
**Docs to update**: `documents/engineering/acme_provider_guide.md`,
`documents/engineering/envoy_gateway_edge_doctrine.md`,
`documents/engineering/aws_integration_environment_doctrine.md`

### Why Phase 7 reopened

The single ACME `ClusterIssuer` landed by Sprint `7.11` was named with a misleading HTTP-01-claiming
name, but the issuer in fact uses a **DNS-01** Route 53 solver (`acmeRoute53Solver`), not HTTP-01 — the name is
historically inaccurate and contradicts the issuer's own solver. The rename touches one SSoT
constant in `PublicEdge.hs`, both chart `values.yaml` files, and roughly 35 doc/test sites, so it
must land on a wipe-and-rebuild boundary (a live cluster carrying the old issuer name would orphan
the renamed `ClusterIssuer` / `Certificate` references). Separately, `PublicEdge.hs` reads the AWS
substrate hosted-zone id directly from a `PRODBOX_AWS_SUBSTRATE_HOSTED_ZONE_ID` environment variable
— a violation of the
[config_doctrine.md](../documents/engineering/config_doctrine.md) no-`PRODBOX_*`-env-reads contract
that `checkEnvVarConfigReads` does not yet cover for `PublicEdge.hs`. Because both defects are on
Phase 7's owned public-edge surface, the phase reopens for one sprint to close them together.

### Objective

Rename the public-edge ACME issuer to a DNS-01-honest name (one SSoT constant flowing to both chart
`values.yaml` files and the ~35 doc/test sites) on a wipe-and-rebuild boundary; reattribute the
Gateway / listener-cert / redirect / auth route to the `keycloak` chart in the doctrine (it is
currently mis-attributed); fix the `PublicEdge.hs` `PRODBOX_AWS_SUBSTRATE_HOSTED_ZONE_ID` env read
to source the hosted-zone id from settings (`aws_substrate.hosted_zone_id`, via
`substrateHostedZoneId`); and extend `checkEnvVarConfigReads` to scope `PublicEdge.hs` so the env
read cannot reappear.

### Deliverables

- One SSoT DNS-01-honest issuer-name constant in `src/Prodbox/PublicEdge.hs` (replacing the
  prior misleading HTTP-01-claiming `publicEdgeClusterIssuerName` value) flows to every consumer:
  `acmeClusterIssuerSpec` / `acmeRuntimeManifestWith` in `Prodbox.CLI.Rke2`, the AWS path's
  `ensureAwsSubstrateAcmeRuntime` issuer wait, both `charts/keycloak/values.yaml` and
  `charts/gateway/values.yaml` issuer references, and the ~35 doc/test sites that name the old
  issuer. No hand-edited second copy of the name survives.
- The rename lands on a **wipe-and-rebuild boundary** (`prodbox rke2 delete --cascade` then a fresh
  reconcile) so the old-named `ClusterIssuer` / `Certificate` is not orphaned on a live cluster;
  the S3 cert retention key scheme (Sprint `7.11`) restores the retained cert under the new issuer
  name without re-ordering from ZeroSSL.
- The doctrine reattributes the Gateway / listener-cert / HTTP→HTTPS-redirect / auth route to the
  `keycloak` chart (correcting the current mis-attribution in
  `envoy_gateway_edge_doctrine.md`).
- `src/Prodbox/PublicEdge.hs` no longer reads `PRODBOX_AWS_SUBSTRATE_HOSTED_ZONE_ID` from the
  environment; the AWS-substrate hosted-zone id is sourced from settings
  (`aws_substrate.hosted_zone_id` via `substrateHostedZoneId`) per the config doctrine.
- `src/Prodbox/CheckCode.hs::checkEnvVarConfigReads.scopedPaths` is extended to cover
  `src/Prodbox/PublicEdge.hs`, so any future `PRODBOX_*` env read there fails `prodbox check-code`.

### Validation

1. `prodbox check-code` (the extended `checkEnvVarConfigReads` now scans `PublicEdge.hs`; fails on
   any `PRODBOX_*` read).
2. `prodbox test unit` + golden re-acceptance (the renamed issuer flows through the ClusterIssuer
   render goldens).
3. `prodbox docs check` / `prodbox lint docs` (the ~35 doc sites and the route-ownership
   reattribution reconciled).
4. Live wipe-and-rebuild: `prodbox rke2 delete --cascade` then reconcile + `prodbox test all`
   proves the renamed issuer issues / restores the public-edge cert and the canonical suite stays
   green on both substrates.

### Remaining Work

None — closed 2026-06-09. The issuer rename, the route-ownership doctrine correction, the
`PublicEdge.hs` env-read fix, and the `checkEnvVarConfigReads` extension all landed. The live
issuer-rename-on-rebuild (`rke2 delete --cascade` + reconcile, restoring the retained cert under the
new name) and the AWS-substrate `test all` exercise are operator-driven.

## Sprint 7.14: Decrypt-to-Scratch Pulumi Interposition over the Model-B Object-Store ✅

**Status**: Done (code-owned surface) (2026-06-16, wrapper/read/migration/provider path landed and
locally validated)
**Implementation**: `src/Prodbox/Pulumi/EncryptedBackend.hs`, `src/Prodbox/Infra/StackOutputs.hs`, `src/Prodbox/Lifecycle/LiveResidue.hs`, `src/Prodbox/Infra/AwsEksTestStack.hs`, `src/Prodbox/Infra/AwsTestStack.hs`, `src/Prodbox/Infra/AwsEksSubzoneStack.hs`, `src/Prodbox/Infra/AwsSesStack.hs`, `src/Prodbox/Infra/LongLivedPulumiBackend.hs`, `src/Prodbox/Aws.hs`
**Live-proof**: pending — the live AWS first-touch migration/deletion proof and the both-substrate
sealed-Vault opacity proof are tracked as a non-blocking live-infra note per
[development_plan_standards.md → O. Code-Local vs Live-Infra Proof](development_plan_standards.md#o-code-local-completion-vs-live-infra-proof).
They consume the `aws_admin_for_test_simulation.*` TestPlaintext fixture that Sprint `7.16` lands
in `test-secrets.dhall` (the fixture is never a Vault object), and never gate this sprint's
code-owned closure or any earlier phase.
**Independent Validation**: Validatable on this sprint's owned surface now — the wrapper, read,
migration, and provider-resolution paths build and pass local validation (`dev check`, `test unit`,
`test integration cli`/`env`) plus the live home-substrate reconcile recorded below; the AWS
first-touch and sealed-opacity proofs are the live-infra axis (Standard O), not a block.
**Docs to update**: `documents/engineering/vault_doctrine.md`, `documents/engineering/aws_admin_credentials.md`, `documents/engineering/aws_integration_environment_doctrine.md`

### Objective

Interpose prodbox between Pulumi and MinIO so Pulumi never touches the object-store directly. Each
Pulumi operation hydrates its stack checkpoint into a RAM-tmpfs `file://` backend (decrypt), runs
`pulumi`, then re-envelopes and opaque-names the result back through the Model-B object-store
(`vault_doctrine §10`). The persistent volume only ever holds opaque ciphertext, even mid-run.
**Pulumi's own secrets provider is dropped** — the prodbox Vault-Transit envelope from Sprint `4.30`
*is* the encryption, so there is no Pulumi passphrase and no second crypto layer. This treatment is
**uniform**: the per-run stacks (`aws-eks`, `aws-eks-subzone`, `aws-test`) and the long-lived
`aws-ses` backend are stored identically — the historical `aws-ses` AES256-SSE-only carve-out is
retired. Vault is the sole authority over Pulumi backend state: a sealed Vault makes every backend
opaque and fails every `aws stack` op closed.

### Deliverables

- `Prodbox.Pulumi.EncryptedBackend.withDecryptedStack` is the bracket every Pulumi op runs inside:
  it gates on the Vault-readiness check (`vaultGateOutcome` from Sprint `1.37`), reads the stack
  checkpoint via the §9 object-store (`getLogical (LogicalPulumiStack sid)`), hydrates a RAM-tmpfs
  `file://.../.pulumi/stacks/<project>/<sid>.json`, runs `pulumi login file://…; pulumi <op>`
  **without a passphrase**, re-envelopes the result via `putLogical`, and shreds the scratch tmpfs
  on exit (success, failure, or signal).
- The interposition is applied **uniformly** to the per-run runners
  (`AwsEksTestStack.hs`, `AwsTestStack.hs`, `AwsEksSubzoneStack.hs`) **and** the main long-lived
  `AwsSesStack.hs` paths. The AES256-SSE-only long-lived carve-out is removed from the supported
  path; the long-lived backend goes through the same enveloped/opaque-named object-store.
- **Pulumi's own secrets provider is dropped**: the stack runners use a scratch `file://` backend
  with `--secrets-provider plaintext`, `fileBackendEnvironment` strips raw backend credentials and
  `PULUMI_CONFIG_PASSPHRASE`, and no Pulumi passphrase / `secretsprovider` is configured.
- Production stack list/output reads (`src/Prodbox/Infra/StackOutputs.hs`) consult encrypted
  checkpoint presence (gated behind unseal) rather than listing raw MinIO keys. Sprint `7.14`
  chooses deterministic direct addressing for Pulumi checkpoints:
  `LogicalPulumiStack <stack-id>` flows through `opaqueObjectId`, so the general Model-B index is not
  required for stack presence.
- AWS **input** credentials Pulumi needs (the access key / secret the provider authenticates with)
  are held as Vault KV objects, referenced from Dhall as `SecretRef.Vault` only — there is no
  plaintext AWS secret field in `prodbox-config.dhall`. The elevated / admin credential is
  prompted, used to provision a least-privilege identity stored in Vault KV, and discarded; it is
  never written to `prodbox-config.dhall`.
- The empty-passphrase → enveloped migration: a backend currently written under the empty
  Pulumi passphrase (or the `aws-ses` AES256-SSE bucket) is read once on first touch, re-stored as
  an opaque `objects/<id>.enc` envelope through the object-store, and the old raw key is deleted.

### Current State

- `Prodbox.Pulumi.EncryptedBackend` exists and is wired into the main apply/destroy cycles for
  `aws-eks`, `aws-eks-subzone`, `aws-test`, and `aws-ses`. It gates on unsealed Vault before
  loading state, reads and writes `LogicalPulumiStack <stack-id>` through the Model-B object-store,
  hydrates Pulumi's real local-backend path
  (`.pulumi/stacks/<Pulumi.yaml project name>/<stack-id>.json`), runs against a scratch `file://`
  backend, and removes scratch state when the bracket exits.
- `fileBackendEnvironment` rewrites `PULUMI_BACKEND_URL` to the scratch `file://` backend and strips
  raw backend AWS credentials plus `PULUMI_CONFIG_PASSPHRASE`. Stack creation uses
  `--secrets-provider plaintext`, so the only durable encryption layer is the prodbox envelope.
- Per-run runners (`AwsEksTestStack`, `AwsEksSubzoneStack`, `AwsTestStack`) now build two separate
  environments: `pulumiProviderBaseEnv` feeds supported Pulumi actions with provider-only input,
  while `pulumiBackendBaseEnv` is passed only inside `LegacyPulumiBackend` for first-touch raw
  checkpoint export/delete. The wrapper still strips backend credentials defensively before Pulumi
  starts against scratch.
- Production residue and output reads now use `StackOutputs.listEncryptedStack` and
  `StackOutputs.fetchEncryptedOutputs`: checkpoint presence is determined from a decryptable
  encrypted object, and `pulumi stack output --show-secrets --json` runs only against the scratch
  file backend.
- The `aws-ses` main reconcile/destroy/SMTP-sync paths no longer require or export the long-lived
  S3 backend environment. They pass provider credentials into the encrypted wrapper; `aws-ses
  migrate-backend` is also wrapper-backed and uses the legacy long-lived S3 backend only as an
  optional first-touch checkpoint source when encrypted state is absent.
- `Prodbox.Infra.AwsProviderCredentials` is the shared provider-credential resolver for per-run
  Pulumi stacks and AWS-stack cleanup helpers. It requires the Vault KV object
  `secret/gateway/gateway/aws`; a missing, sealed, unreachable, or invalid object fails loud before
  Pulumi receives provider credentials. There is no raw `aws.*` /
  `aws_admin_for_test_simulation.*` fallback on the Pulumi provider path.
- The home-cluster bootstrap path now resolves the Vault-backed operational `aws.*` gate before
  deploying the Route 53-writing gateway chart or admin public-edge routes. Missing or empty
  `secret/gateway/gateway/aws` is treated as an absent operational credential for bare
  `cluster reconcile`, so the local substrate reaches a clean platform state and skips the gateway
  daemon instead of deploying pods that fail on unresolved `SecretRef.Vault` values. Unexpected Vault
  failures still fail the reconcile.
- `withMigratedDecryptedStackEnvironment` provides first-touch migration for legacy checkpoint
  layouts: if the encrypted `LogicalPulumiStack` object is absent, it logs into the legacy backend,
  exports the stack checkpoint to a temp file, hydrates scratch from those bytes, stores/deletes via
  the encrypted object-store after the Pulumi action, and removes the legacy stack only after the
  encrypted operation succeeds. The per-run stacks pass their old MinIO backend env as the legacy
  source; `aws-ses` constructs an optional long-lived S3 legacy source from `pulumi_state_backend`
  when that config exists.
- Pulumi checkpoint presence uses deterministic direct addressing:
  `LogicalPulumiStack <stack-id>` -> `opaqueObjectId` -> `objects/<hmac>.enc`. The general Model-B
  index remains available for other logical-object classes, but Sprint `7.14` does not need an
  additional id↔logical index or MinIO lock object for stack presence.

### Validation

- Current code-owned validation (2026-06-16): `cabal build --builddir=.build exe:prodbox`, Haskell
  lint with no hints, focused Sprint `7.14` units 9/9, focused operational AWS-credential gate
  units 2/2, focused Vault KV object units 3/3, Sprint `4.16` residue/StackOutputs units 54/54,
  Sprint `4.10` long-lived-backend/admin-credential units 12/12, full unit suite 950/950,
  `./.build/prodbox test integration cli` 38/38, `./.build/prodbox test integration env` 38/38,
  docs check/lint 0, `git diff --check` 0, and canonical `./.build/prodbox dev check` 0.
- Live home-substrate bootstrap validation (2026-06-16): `./.build/prodbox cluster reconcile`
  completed with Vault initialized/unsealed, MinIO and Harbor healthy, image publication/import
  working, MetalLB/Envoy/cert-manager/Percona reconciled, gateway MinIO bootstrap passing, and the
  gateway release cleanly skipped because operational `aws.*` was absent from Vault. Follow-up
  inspection showed no gateway Helm release and no CrashLoopBackOff pods.
- Live AWS-substrate validation attempts (2026-06-16; live-proof axis only, non-blocking per
  Standard O — the code-owned surface is already Done): `./.build/prodbox test integration aws-eks
  --substrate aws` stopped in the IAM harness preflight before provisioning because the harness
  could not obtain a test-simulation admin credential. The harness reported that
  `aws_admin_for_test_simulation.access_key_id`, `secret_access_key`, and `region` must be present
  before it can mint temporary operational credentials. No AWS stack reconcile or AWS resource
  provisioning began in this attempt. **(Sprint `7.16` supersedes the dated assumption that this
  fixture is sourced from Vault: it is a TestPlaintext fixture that lives only in `test-secrets.dhall`
  — none of our testing secrets live in Vault — and the harness reads it from there to simulate the
  operator typing the ephemeral elevated credential at the interactive `SecretRef.Prompt`.)**
- Live-proof (pending, non-blocking per Standard O): a MinIO dump of the Pulumi backend while Vault
  is
  sealed reveals only opaque `objects/<hmac>.enc` ciphertext — no `aws-eks` / stack-name key, no
  resource names, no account IDs, no topology — for **both** per-run and `aws-ses` backends.
- Live-proof (pending, non-blocking per Standard O): sealed Vault blocks
  `prodbox aws stack <stack> reconcile` / `destroy` with a clear safe error before any Pulumi op
  starts, and a host-disk walk of `.data/prodbox/minio/0` mid-run shows only opaque ciphertext while
  the decrypted checkpoint lives only in RAM-backed scratch.

### Remaining Work

This sprint is Done on its code-owned surface; everything below is the non-blocking
`Live-proof: pending` axis (Standard O), not a block.

- Live-verify first-touch migration/deletion for old empty-passphrase / raw MinIO checkpoints and
  the former `aws-ses` long-lived S3 backend across both substrates, including a host-disk proof
  that no plaintext raw checkpoint survives after the encrypted migration.
- Live-proof forward ordering with Sprint `7.16`: `7.16`'s only dependency was this sprint's landed
  code, and `7.16` has landed the
  `aws_admin_for_test_simulation.*` TestPlaintext fixture in `test-secrets.dhall` (the fixture is
  never stored in Vault), this sprint's live first-touch/deletion and sealed-opacity proofs consume
  that fixture to reach actual AWS stack operations. This is a one-directional live-proof
  consumption, not a mutual block.
- Decide whether to remove the now-wrapper-backed
  `prodbox aws stack aws-ses migrate-backend` compatibility alias after live migration proof. It no
  longer performs raw `pulumi stack export` / `pulumi stack import` between MinIO and long-lived S3.
- The both-substrate live exercise (sealed-Vault opacity across per-run and `aws-ses` backends) is
  operator-driven and shares the Sprint `5.8` cross-surface red-team gate.

## Sprint 7.15: ACME EAB and TLS Key Material Behind Vault ✅

**Status**: Done (2026-06-17) on its code-owned surface — locally validated: `dev check` 0,
`test unit` 0 (954, incl. a new plaintext-EAB-rejection leak guard), `test integration cli` 0,
`test integration env` 0.
**Implementation**: `acme.eab_key_id` / `acme.eab_hmac_key` are now `Optional SecretRef.Vault`
(default `secret/acme/eab` fields `key_id` / `hmac_key`) in `prodbox-config-types.dhall` and
`src/Prodbox/Settings.hs` (`AcmeSection` + decoder; `validateAcmeBinding` rejects plaintext EAB via
`validateVaultRef`, keeping the ZeroSSL both-or-neither rule). The host-applied ACME `ClusterIssuer`
(`src/Prodbox/CLI/Rke2.hs`) renders the EAB HMAC through a Vault-login materializer Job in
`cert-manager` (`acme-eab-secret-materializer` SA/Role/RoleBinding + Job, mirroring the Sprint `3.18`
vscode-SecurityPolicy materializer); the non-secret key ID is host-resolved (`resolveAcmeEabKeyId`)
and rendered inline; `ensureAcmeRuntime` fails closed if Vault cannot resolve it.
`src/Prodbox/Lib/AwsSubstratePlatform.hs` threads it identically on the AWS substrate.
`src/Prodbox/Secret/VaultInventory.hs` adds the `secret/acme/eab` object + the `acme` consumer
(policy/role/SA in `cert-manager`); `src/Prodbox/ContainerImage.hs` adds the materializer Vault
image; `src/Prodbox/Aws.hs` `config setup` writes the prompted EAB to `secret/acme/eab` and leaves
the config carrying only `SecretRef.Vault` references. `prodbox config validate` rejects plaintext
EAB. Docs reconciled: `acme_provider_guide.md`, `config_doctrine.md` §6.1,
`envoy_gateway_edge_doctrine.md`, `vault_doctrine.md` §11 + §18.
**Live-proof**: pending — native-Vault-PKI internal-cert issuance and live ZeroSSL issuance
(including a sealed-Vault-blocks-issuance live proof) are the non-blocking live-infra axis
(Standard O); the cert-manager-issuer-vs-native-PKI deep choice remains an open design decision
(vault_doctrine §18). The `SecretRef.Vault` resolver already structurally fails EAB resolution
closed on a sealed Vault. Earlier-phase dependencies (Sprints `1.35`, `1.36`) were satisfied.
**Docs to update**: `documents/engineering/acme_provider_guide.md`, `documents/engineering/envoy_gateway_edge_doctrine.md`, `documents/engineering/vault_doctrine.md`

### Objective

Make Vault the sole TLS authority for the AWS substrate: ACME EAB credentials are Vault KV objects
and TLS private-key material is generated-in / stored-in / wrapped-by Vault (vault_doctrine §11).
A sealed Vault fails new issuance and key retrieval closed. ZeroSSL remains the sole public ACME
provider and the S3 cert retain-and-restore contract is unchanged, but the key material that
contract protects is Vault-owned — there is no plaintext key material a sealed Vault could leak.

### Deliverables

- `acme.eab_key_id` / `acme.eab_hmac_key` are Vault KV objects referenced by `SecretRef.Vault` —
  there are no plaintext EAB config fields.
- TLS private keys are generated-in / stored-in / wrapped-by Vault (Vault PKI for internal certs;
  public ZeroSSL cert key material Vault-protected); certificate-issuance state is not recoverable
  from plaintext Kubernetes Secrets alone.
- The cert-manager-Vault-issuer vs native-Vault-PKI choice is recorded; new issuance and private-key
  retrieval fail closed when Vault is sealed.

### Validation

- A sealed Vault blocks new certificate issuance and private-key reconstruction; restarts fail
  closed.
- The single ZeroSSL issuer + S3 retain-restore behavior is preserved (no re-order on rebuild),
  with its key material Vault-protected.

### Remaining Work

- The both-substrate live TLS exercise is operator-driven.

## Sprint 7.16: Test-Simulation Credentials Move to test-secrets.dhall; Admin Acquisition Unifies on the Prompt ✅

**Status**: Done (2026-06-17) on its code-owned surface — locally validated: `dev check` 0,
`test unit` 0, `test integration cli` 0, `test integration env` 0.
**Implementation**: `aws_admin_for_test_simulation` removed from `prodbox-config-types.dhall` and the
`ConfigFile` record (`src/Prodbox/Settings.hs`); committed `test-secrets-types.dhall` schema; new
`src/Prodbox/Aws/AdminCredentials.hs` — `acquireAdminAwsCredentials`, the single ephemeral
admin-credential seam (`test-secrets.dhall` fixture → TTY prompt → fail-loud), placed low in the
import graph to avoid a cycle; `src/Prodbox/Vault/Host.hs` owns `TestSecrets` /
`loadTestSecrets`; re-pointed consumers
`src/Prodbox/Infra/LongLivedPulumiBackend.hs`, `src/Prodbox/Aws.hs`,
`src/Prodbox/Infra/AwsSesStack.hs`, `src/Prodbox/CLI/Nuke.hs`, `src/Prodbox/CLI/Rke2.hs`,
`src/Prodbox/Lifecycle/LiveResidue.hs`, `src/Prodbox/EffectInterpreter.hs`; `.gitignore`;
fixtures `test/golden/destructive/nuke.txt`,
`test/unit/Main.hs`, `test/integration/CliSuite.hs`, `test/integration/EnvSuite.hs`. `prodbox config
validate` rejects any plaintext admin/operational AWS key in `prodbox.dhall`; the SecretRef
golden tests and sealed-state oracle remain meaningful (no leak-guard weakened).
**Live-proof**: pending — the live AWS exercise of the harness-simulated admin prompt path (the
suite-level IAM bring-up against real AWS) is a non-blocking live-infra axis (Standard O). Its
dependency, Sprint `7.14`'s landed `SecretRef.Vault` treatment of `aws.*`, was satisfied; this
sprint's `test-secrets.dhall` fixture is consumed one-directionally by `7.14`'s own
`Live-proof: pending` axis.
**Independent Validation**: Validatable on its own surface — the config-schema move,
`test-secrets.dhall` introduction, prompt unification, and `config validate` rejection all build and
pass local validation (`check-code`, `test unit`, `test integration`, `test all` on the home
substrate) with no dependency on a later phase.
**Docs to update**: `documents/engineering/vault_doctrine.md` (§3 SecretRef model, §4 config
split, §13 classification), `documents/engineering/aws_admin_credentials.md`,
`documents/engineering/config_doctrine.md`,
`documents/engineering/aws_integration_environment_doctrine.md`,
`documents/engineering/aws_account_setup_guide.md`,
`documents/engineering/lifecycle_reconciliation_doctrine.md` (§2 per-stack credential-class
assignment), `DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md`, `DEVELOPMENT_PLAN/README.md`,
`DEVELOPMENT_PLAN/00-overview.md`, `DEVELOPMENT_PLAN/system-components.md`

### Objective

Converge the credential model on three strictly distinct roles and one runtime admin-acquisition
path. There is exactly one way elevated/admin AWS power enters prodbox at runtime: the interactive
`SecretRef.Prompt` (prompt-use-discard — held in memory for one command, used once to mint the
dedicated least-privilege `prodbox` IAM identity, then discarded; never written to
`prodbox.dhall`, never stored in Vault, never persisted to disk). The generated operational
`prodbox` IAM credential (the `aws.*` section) is minted into Vault KV
(`secret/gateway/gateway/aws`) the instant it is created, with `prodbox.dhall` carrying only
a `SecretRef.Vault` reference to it; because it is minted into Vault, the mint step runs after Vault
is set up and unsealed. The `aws_admin_for_test_simulation.*` block is a TestPlaintext test-harness
fixture whose sole purpose is to drive the UI — feeding the same interactive prompts a real operator
answers so the harness can exercise admin-credentialed flows non-interactively — and it lives only
in `test-secrets.dhall`, never imported by `prodbox.dhall`, never read by any production
binary, never stored in Vault. None of our testing secrets live in Vault; Vault holds production
secrets only. Sequencing: bring up + unseal Vault → (operator at the prompt, or the harness
simulating it from `test-secrets.dhall`) supplies the ephemeral elevated credential → prodbox mints
the dedicated least-privilege `prodbox` IAM identity → writes the generated `aws.*` credential into
Vault KV → discards the prompted elevated credential. This SSoT statement is owned by
[vault_doctrine.md §§3/4/13](../documents/engineering/vault_doctrine.md),
[aws_admin_credentials.md](../documents/engineering/aws_admin_credentials.md), and
[lifecycle_reconciliation_doctrine.md §2](../documents/engineering/lifecycle_reconciliation_doctrine.md);
this sprint adopts it rather than restating it.

### Deliverables

- Remove the `aws_admin_for_test_simulation` block from `prodbox.dhall` and
  `prodbox-config-types.dhall`.
- Introduce a test-harness-only `test-secrets.dhall` (TestPlaintext) consumed only by the
  suite-level IAM harness to simulate the operator prompt. It carries the test-only plaintext that
  simulates operator prompts and seeds fixtures (the Vault unlock-bundle password, the
  `aws_admin_for_test_simulation.*` fixture, fake ACME/EAB values, fake MinIO/Keycloak bootstrap,
  Vault seed fixtures); it is never imported by `prodbox.dhall`, never in Vault, never in
  production.
- Unify `aws-ses` reconcile/destroy/migrate-backend and `prodbox nuke` admin acquisition on the
  interactive `SecretRef.Prompt`, with the harness simulating it from `test-secrets.dhall` (retire
  `loadAdminAwsCredentials` / `pulumiSes*BaseEnv` reading a stored config block). There is no
  production config-backed admin path.
- Mint the generated operational `aws.*` into Vault KV (`secret/gateway/gateway/aws`) only after
  Vault is unsealed, with `prodbox.dhall` carrying only the `SecretRef.Vault` reference (the
  generated credential never transits cleartext storage).
- `prodbox config validate` rejects any plaintext admin/operational AWS key present in
  `prodbox.dhall` (production-safe topology + unencrypted basics + `SecretRef` references
  only; no plaintext secrets, no `aws_admin_for_test_simulation` block).
- **Per-host migration (operator-driven; all three files are git-ignored / not version-controlled):**
  the new executable-sibling `prodbox.dhall` shape and the new `test-secrets.dhall` are
  **created from the operator's existing legacy `prodbox-config.dhall`** — the `aws_admin_for_test_simulation.*`
  block and the Vault unlock-bundle password are extracted into `test-secrets.dhall` (importing
  `test-secrets-types.dhall`), and the remaining production fields (`aws.*`, `acme.eab_*`) are
  rewritten to the schema's default `SecretRef.Vault` references. The existing on-disk
  `prodbox-config.dhall` is the migration *source* even though none of the three files are version
  controlled — the plan records the derivation so any operator (or agent) migrating a host knows the
  source of truth for the one-time conversion. Mechanism: a `prodbox config migrate` helper that
  reads the existing file and emits the two new disposable files, or `prodbox config setup`
  regeneration (to be decided). This is **non-blocking** operator migration (it does not gate this
  sprint's code-owned closure and is not a later-phase dependency, per Standard O).

### Validation

1. `prodbox check-code`
2. `prodbox test unit`
3. `prodbox config validate` rejects a `prodbox.dhall` carrying any plaintext admin or
   operational AWS key, and rejects an `aws_admin_for_test_simulation` block.
4. `prodbox test integration aws-iam` drives the harness from `test-secrets.dhall` and proves the
   mint-into-Vault-after-unseal ordering.
5. `prodbox test all` (home substrate) stays green.

### Remaining Work

- Landed (2026-06-17) on the code-owned surface: the config-schema removal, `test-secrets.dhall`
  introduction, the `Prodbox.Aws.AdminCredentials` prompt-unification seam, the Vault-KV mint
  ordering, and the `config validate` plaintext rejection. The live AWS-substrate exercise of the
  harness-simulated prompt path shares the operator-driven `Live-proof: pending` gate (Standard O).
- Per-host operator migration — deriving the new executable-sibling `prodbox.dhall` +
  `test-secrets.dhall` from the existing legacy `prodbox-config.dhall` (see Deliverables) — is
  non-blocking operator work.

## Sprint 7.17: Generate the Dhall Config Schemas from the Haskell Source of Truth ✅

**Status**: Done (2026-06-17) on its code-owned surface — locally validated: `dev check` 0,
`test unit` 0 (962, incl. the round-trip drift guard), `test integration cli` 0,
`test integration env` 0, `docs check`/`lint docs` 0.
**Implementation**: the Haskell `ConfigFile` / `defaultConfigFile` / `SecretRef` (+ `TestConfig`)
types are now the single source of truth. New pure renderer `src/Prodbox/Config/SchemaDhall.hs`
derives the schema from them — `Dhall.expected (auto @ConfigFile)` for the record `Type` (so it
cannot drift from the decoder) and `Dhall.inject`/`embed` over `defaultConfigFile` for the `default`
record, hoisting the `SecretRef` union into a top-level `let`; `ToDhall` instances added in
`src/Prodbox/Settings.hs`, `src/Prodbox/Settings/SecretRef.hs`, `src/Prodbox/Vault/Host.hs`
(+ `defaultTestConfig`); a `prodbox config schema` command (`src/Prodbox/CLI/Command.hs`,
`src/Prodbox/CLI/Spec.hs`, `src/Prodbox/Native.hs`) writes both files, and `config setup` /
`config validate` auto-materialize them when absent or stale; `.gitignore` ignores
`prodbox-config-types.dhall` + `test-secrets-types.dhall`; both schema files regenerated as the
renderer output; six round-trip drift-guard unit tests (`test/unit/Main.hs`) prove a default config
authored against the *generated* schema decodes to `defaultConfigFile` / `defaultTestConfig` and that
the on-disk files equal the renderer output. Generated CLI artifacts
(help/goldens/man/completions/`documents/cli/commands.md`) regenerated for the new command.
**Operator follow-up (not doable under the git-workflow policy):** a one-time
`git rm --cached prodbox-config-types.dhall` untracks the already-tracked schema file (the file stays
on disk, regenerated by the binary); recorded in `.gitignore` and the legacy ledger.
**Blocked by**: Sprint `1.35` (the `SecretRef` union) and Sprint `7.16` (which split
`test-secrets-types.dhall` and finalized the post-credential-migration `ConfigFile` shape) — both
earlier-or-same-phase landed code. Forward-only (Standard N): this sprint sits in Phase 7, **not**
Phase 1, precisely because it consumes Sprint `7.16`'s `test-secrets-types.dhall`; scheduling it in
Phase 1 would create a forbidden backward `Blocked by` on a later phase. (Phase 1 still owns the
config *foundations* — the decode, types, and validation; this sprint adds a generation step
sequenced after the last schema-shape change.)
**Live-proof**: n/a — fully code-owned and locally validatable.
**Independent Validation**: a unit round-trip test proves the emitted Dhall schema matches the
Haskell decoder (a default config authored against the generated `prodbox-config-types.dhall`
decodes via `Dhall.inputFile auto` to `defaultConfigFile`); validated by `dev check` + `test unit` +
`test integration cli`/`env` on the phase's own surface, with no later-phase dependency.
**Docs to update**: `documents/engineering/config_doctrine.md`, `documents/engineering/code_quality.md`
(generated-artifacts model), `documents/documentation_standards.md` (§6 "Committed Dhall Imports" —
the schema files are no longer committed co-edited siblings),
`DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md`, `DEVELOPMENT_PLAN/README.md`,
`DEVELOPMENT_PLAN/00-overview.md`, `DEVELOPMENT_PLAN/system-components.md`

### Objective

The config schema exists twice today: as the Haskell `ConfigFile` / `defaultConfigFile` /
`SecretRef` types decoded via `Dhall.inputFile auto` (the real source of truth the binary enforces),
and as the hand-maintained, version-controlled `prodbox-config-types.dhall` + `test-secrets-types.dhall`
that the operator's `prodbox-config.dhall` / `test-secrets.dhall` import. The two must be kept in sync
by hand — a drift risk with no integrity benefit. Make the Haskell types the **single source of
truth** and generate the Dhall schemas from them, then **remove the schema files from version
control**: `prodbox-config-types.dhall` and `test-secrets-types.dhall` become binary-emitted,
git-ignored artifacts that join the already-disposable `prodbox-config.dhall` / `test-secrets.dhall`
(none of the four is version-controlled). Operator ergonomics are preserved — the generated schema
still carries the record `Type`, the `default` record (for `Config::{ overrides }` completion), and
the `SecretRef` union, so the operator's config files keep importing it and Dhall still typechecks
the config at author time, against a schema that can no longer drift from what the binary decodes.

### Deliverables

- A pure renderer that emits the Dhall schema (record `Type` + `default` record + the `SecretRef`
  union) from the Haskell `ConfigFile` / `defaultConfigFile`, and the test-config schema from the
  `TestConfig` types — the Haskell source is authoritative.
- The binary materializes `prodbox-config-types.dhall` + `test-secrets-types.dhall` locally on demand
  (a `prodbox config schema` command, and/or auto-regeneration by `config setup` / `config validate`
  when the file is absent or stale), so the operator's `import ./prodbox-config-types.dhall` resolves.
- `prodbox-config-types.dhall` and `test-secrets-types.dhall` are **removed from version control** and
  added to `.gitignore` — no longer committed, hand-maintained source. They are git-ignored
  materialized-on-demand artifacts, distinct from the committed `TrackedGeneratedPath`
  files (man pages, completions); the drift guard is the round-trip unit test below, not a
  committed-file diff.
- A drift-guard unit test: a default config authored against the generated schema decodes via
  `Dhall.inputFile auto` to `defaultConfigFile`, so the single source of truth cannot silently
  diverge from what the binary enforces.

### Validation

- `prodbox dev check`, `prodbox test unit` (incl. the schema round-trip drift guard),
  `prodbox test integration cli`/`env` all green.
- `git ls-files` no longer tracks `prodbox-config-types.dhall` / `test-secrets-types.dhall`;
  `git check-ignore` confirms both are ignored; after the binary materializes them,
  `prodbox config validate` on a fresh config passes.

### Remaining Work

- Scheduled. Fully code-owned and locally validatable; no live-infra axis.

## Documentation Requirements

The phase-independence doctrine adopted here (Sprint `7.14` reframed to `Done` on its code-owned
surface with a non-blocking `Live-proof: pending` note; Sprint `7.5`/`7.5.c` reframed so live-AWS
proof never blocks an earlier phase; the `Independent Validation` lines) defers to
[development_plan_standards.md → N. Phase Independence](development_plan_standards.md#n-phase-independence-no-backward-blocking)
and [O. Code-Local vs Live-Infra Proof](development_plan_standards.md#o-code-local-completion-vs-live-infra-proof)
as SSoT; the doctrine-adoption sprint and the relocated reopen narrative are recorded in
[legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md).

**Engineering docs to create/update:**

- `documents/engineering/aws_account_setup_guide.md` - Haskell onboarding and temporary admin
  credential workflow.
- `documents/engineering/aws_admin_credentials.md` - Haskell `aws_admin_for_test_simulation`
  harness and cleanup rules.
- `documents/engineering/acme_provider_guide.md` - ACME provider choice in the rewritten setup
  flow.
- `documents/engineering/cli_command_surface.md` - `config setup` and `aws *` command matrix.
- `documents/engineering/aws_integration_environment_doctrine.md` - retained AWS admin rules after
  the rewrite.
- `documents/engineering/integration_fixture_doctrine.md` - shared named-and-aggregate IAM
  validation harness cleanup ownership.
- `documents/engineering/unit_testing_policy.md` - IAM lifecycle proof ownership on the Haskell
  stack.
- `documents/engineering/aws_integration_environment_doctrine.md` - Sprint `7.6` refuse-path +
  auto-destroy doctrine plus the `--allow-pulumi-residue` escape hatch.
- `documents/engineering/acme_provider_guide.md` - Sprint `7.11` single ZeroSSL issuer
  (`zerossl-dns01`) with its DNS-01 Route 53 solver and required EAB.
- `documents/engineering/envoy_gateway_edge_doctrine.md` - Sprint `7.11` public-edge cert sourcing
  from the single ZeroSSL issuer and the substrate-scoped cert retention store.
- `documents/engineering/config_doctrine.md` - Sprint `7.11` `acme.server` ZeroSSL default and the
  EAB-required validation shape.
- `documents/engineering/helm_chart_platform_doctrine.md` - Sprint `7.12` substrate-equivalence
  structural invariant: the single `Prodbox.ContainerImage` Envoy release value pinned across chart
  + control plane + data plane, the per-substrate re-pin lint, and the shared `[PlatformComponent]`
  inventory covered by both installers (a coverage test, not a unified step DAG).
- `documents/engineering/envoy_gateway_edge_doctrine.md` - Sprint `7.12` single Envoy Gateway
  release value (killing the EG-`1.4.4`/Envoy-`1.37` skew); Sprint `7.13` DNS-01-honest issuer
  rename and the Gateway / listener-cert / redirect / auth route reattributed to the `keycloak`
  chart.
- `documents/engineering/aws_integration_environment_doctrine.md` - Sprint `7.12` corrected
  "Harbor + MinIO + Percona on both substrates" prose (no "no-Harbor on EKS"); Sprint `7.13`
  `aws_substrate.hosted_zone_id` sourced from settings (no `PRODBOX_AWS_SUBSTRATE_HOSTED_ZONE_ID`
  env read).
- `documents/engineering/acme_provider_guide.md` - Sprint `7.13` DNS-01-honest issuer rename (one
  SSoT constant) replacing the historically-inaccurate HTTP-01-claiming name on a
  wipe-and-rebuild boundary.
- [documents/engineering/vault_doctrine.md](../documents/engineering/vault_doctrine.md) - Sprint
  `7.14` decrypt-to-scratch Pulumi interposition: each `aws stack` op hydrates its checkpoint into a
  RAM-tmpfs `file://` backend, runs `pulumi` without a passphrase, and re-envelopes opaque-named
  objects back through the Model-B object-store
  ([§9](../documents/engineering/vault_doctrine.md#9-minio-as-a-ciphertext-store),
  [§10](../documents/engineering/vault_doctrine.md#10-pulumi-backend-under-vault)) — applied
  uniformly to per-run and long-lived (`aws-ses`) backends, with Pulumi's own secrets provider
  dropped (the prodbox envelope is the encryption) and a sealed-Vault readiness gate on every op.
  AWS input credentials prodbox creates are held in Vault KV referenced by `SecretRef.Vault`
  ([§13](../documents/engineering/vault_doctrine.md#13-config-and-state-classification)); Sprint
  `7.15` ACME EAB + TLS private-key material as Vault-owned objects that fail closed when Vault is
  sealed ([§11](../documents/engineering/vault_doctrine.md#11-tls-and-pki-under-vault)). Vault is the
  sole authority over both surfaces: the per-run and long-lived backend lifetime classes and the
  single ZeroSSL issuer + S3 retain-restore behavior are unchanged, but their secret and key
  material is Vault-owned with no plaintext fallback.
- `documents/engineering/aws_admin_credentials.md` - Sprint `7.14` elevated/admin AWS credential
  stored as a least-privilege identity in Vault KV (never written to `prodbox-config.dhall`).
- `documents/engineering/envoy_gateway_edge_doctrine.md` - Sprint `7.15` public-edge TLS
  private-key material wrapped by Vault; new issuance and private-key retrieval fail closed when
  Vault is sealed.
- [documents/engineering/vault_doctrine.md](../documents/engineering/vault_doctrine.md) - Sprint
  `7.16` SSoT for the SecretRef model (§3), the two-config-file split (§4 — `prodbox-config.dhall`
  carries `SecretRef` references only; `test-secrets.dhall` carries all test-only plaintext), and
  classification (§13 — the generated operational `aws.*` is `SecretRef.Vault`; the
  `aws_admin_for_test_simulation.*` fixture is TestPlaintext that never enters Vault).
- `documents/engineering/aws_admin_credentials.md` - Sprint `7.16` owns the
  `aws_admin_for_test_simulation` block specifics: a TestPlaintext test-harness fixture in
  `test-secrets.dhall` that simulates the interactive elevated-credential prompt; never imported by
  `prodbox-config.dhall`, never read by a production binary, never stored in Vault.
- `documents/engineering/config_doctrine.md` - Sprint `7.16` `prodbox config validate` rejects any
  plaintext admin/operational AWS key or `aws_admin_for_test_simulation` block in
  `prodbox-config.dhall`.
- `documents/engineering/aws_integration_environment_doctrine.md` - Sprint `7.16` unified
  admin-acquisition path: real ops prompt for the ephemeral elevated credential via the interactive
  `SecretRef.Prompt`; the harness simulates that prompt from `test-secrets.dhall`.
- `documents/engineering/aws_account_setup_guide.md` - Sprint `7.16` operator onboarding reflects
  prompt-use-discard for the elevated credential and the generated `aws.*` minted into Vault KV
  after unseal.
- [documents/engineering/lifecycle_reconciliation_doctrine.md](../documents/engineering/lifecycle_reconciliation_doctrine.md)
  - Sprint `7.16` §2 per-stack credential-class assignment for the prompt-driven admin path
  (`aws-ses` reconcile/destroy/migrate-backend and `prodbox nuke`).
- `DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md` - Sprint `7.16` Pending-Removal entries: the
  `aws_admin_for_test_simulation` plaintext block in `prodbox-config.dhall` /
  `prodbox-config-types.dhall`, the config-backed admin path for `aws-ses` / `nuke`
  (`loadAdminAwsCredentials` / `pulumiSesProviderBaseEnv` / `pulumiSesAdminBaseEnv` reading the
  stored block), and the historical test-fixture filename (renamed to `test-secrets.dhall`).
- [documents/engineering/resource_scaling_doctrine.md](../documents/engineering/resource_scaling_doctrine.md) -
  for Sprint `7.27`, the managed-cloud-only spot-price gate (§ 4): the per-workload
  `SpotPriceThreshold`, the three-valued `SpotObservation` → `admitSpotDeploy` decision, and the
  `Unreachable → refuse` rule that never deploys on an unobservable price.
- [documents/engineering/storage_lifecycle_doctrine.md](../documents/engineering/storage_lifecycle_doctrine.md) -
  Sprint `7.28` unified block-storage doctrine: the AWS/EKS static pre-created-EBS-as-`Retain`-PV
  model (§ 1, § 3, § 4), the retain-on-teardown / test-delete delete contract (§ 5), and the EBS
  durable-storage parallel to `.data/` (§ 7).
- [documents/engineering/cluster_topology_doctrine.md](../documents/engineering/cluster_topology_doctrine.md) -
  Sprint `7.28` § 4: EKS honors "no dynamic provisioning anywhere" via pre-created EBS lifted as
  static `Retain` PVs, and the EBS PV's `topology.ebs.csi.aws.com/zone` AZ affinity is a
  topology-owned placement concern.
- [documents/engineering/helm_chart_platform_doctrine.md](../documents/engineering/helm_chart_platform_doctrine.md) -
  Sprint `7.28` § 3A/§ 6: the block-storage volume source is a deliberate per-substrate difference
  (hostPath on home, pre-created EBS on EKS) while the static `Retain` no-provisioner discipline is
  identical across both.
- [substrates.md](substrates.md) - Sprints `7.28`/`7.29` AWS Substrate inventory rows and the
  Substrate Equivalence structural invariant (block storage now equivalent); the EBS
  managed-resource class enters the generated `resource-lifecycle-classes` table via Sprint `4.39`.
- `DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md` - Sprint `7.28` Completed entry: the dynamic
  `gp2` EKS storage path, `awsChartStorageClassName`, and `chartDynamicStorageManifest` (AWS usage)
  removed by the static retained-EBS PV cutover.

**Product docs to create/update:**

- None.

**Cross-references to add:**

- Keep the onboarding and AWS administration docs linked from
  [documents/engineering/README.md](../documents/engineering/README.md).
- Cross-reference [substrates.md](substrates.md) Resource Lifecycle Classes (LongLived) for the
  Sprint `7.11` public-edge production cert (rendered by the generated `resourceLifecycleClasses`
  table).

## Sprint 7.18: Non-Interactive ACME EAB Seeding + Materializer Handoff Fix ✅

**Status:** ✅ Done (code-owned surface); 🧪 Live-proof: **passed** on the home substrate
(`zerossl-dns01` `Ready=True (ACMEAccountRegistered)` with the real ZeroSSL EAB). `dev check` 0,
`test unit` 0 (966, incl. a 3-test EAB-seeding block), `test integration cli`/`env` 0.

**Why.** Sprint `7.15` made the ACME EAB a Vault KV object materialized in-cluster, and Sprint
`7.16` moved the cleartext test fixtures to `test-secrets.dhall`. But the public edge could not be
brought up non-interactively: a real operator seeds `secret/acme/eab` via the interactive
`prodbox config setup` prompt, which an automated `prodbox test all` / `edge reconcile` run cannot
drive. The home public-edge proof therefore failed at the ZeroSSL ClusterIssuer with the opaque
`acme: cannot sign JWS with an empty MAC key`. Live diagnosis isolated **two stacked defects**:

1. **Seeding ordering / source.** Nothing seeded `secret/acme/eab` from the test fixture before the
   in-cluster materializer Job read it, so the materializer read an empty `hmac_key`. Fix:
   `seedAcmeEabFromTestConfig` (relocated to `Prodbox.Vault.Host`, low in the import graph) loads the
   optional `acme_eab` block of `test-secrets.dhall` and writes `secret/acme/eab` (`key_id` +
   `hmac_key`); it is invoked in `ensureAcmeRuntime` (`src/Prodbox/CLI/Rke2.hs`) **immediately before**
   the ACME-runtime manifest (which includes the materializer Job) is applied. It is a strict no-op
   when `test-secrets.dhall` is absent or its `acme_eab` is empty — real operators are unaffected and
   still seed the EAB through the interactive prompt. (The harness preflight retains a
   belt-and-suspenders call.)
2. **Cross-container handoff permission.** The materializer's `vault-secrets` init container (vault
   image) wrote the HMAC handoff file under `umask 077` (mode 0600, owned by the init UID), but the
   sibling `materialize-eab-secret` container (curl image) runs as a different non-root UID and got
   `Permission denied` reading it — so `base64` read nothing and the materialized
   `acme-eab-credentials` Secret was silently empty. Fix: `chmod 0644` the handoff file (a pod-scoped
   in-memory `emptyDir`, so the secret stays inside the pod trust boundary), plus a **fail-loud
   guard** — an empty HMAC now aborts the Job (within `backoffLimit`) instead of materializing an
   empty Secret that surfaces only later as the opaque ZeroSSL error.

**Live proof (home substrate, 2026-06-17).** `prodbox edge reconcile` seeded `secret/acme/eab`
(verified version-2 `hmac_key` = the real 86-char ZeroSSL key via an in-cluster read using the
`acme` Vault role), the materializer materialized the `acme-eab-credentials` Secret with the
non-empty HMAC, and `zerossl-dns01` reached `Ready=True (ACMEAccountRegistered)` —
`status.acme.uri = https://acme.zerossl.com/v2/DV90/account/...`. The Route 53 DNS bootstrap record
was submitted in the same reconcile.

**Files:** `src/Prodbox/Vault/Host.hs` (canonical `seedAcmeEabFromTestConfig`),
`src/Prodbox/CLI/Rke2.hs` (`ensureAcmeRuntime` seed call before manifest apply; materializer init
`chmod 0644` + empty-HMAC fail-loud guard), `src/Prodbox/Aws.hs` (harness-preflight call re-pointed
to the shared seam), `test/unit/Main.hs` (EAB-seeding tests).

## Sprint 7.19: Tier 1 — Vault Unlock Bundle Relocated to the Durable MinIO Bucket ✅

**Status**: ✅ Done on the code-owned surface (validated 2026-06-18), with the disk-free unseal
cutover closed by Sprint `7.25`'s live home proof on 2026-06-23. `src/Prodbox/Vault/BootstrapBundle.hs`
owns the fixed key `bootstrap/vault-unlock-bundle.v1`, the password-AEAD bundle object IO, and the
prefer-MinIO/fallback-disk read path for the additive stage. The MinIO access credential is a
single static constant (`Prodbox.Minio.RootCredential`, 2026-06-22), superseding the brief
2026-06-21 password-derived approach and fixing the retained-PV rebuild mismatch.
**Blocked by**: Sprint `7.14` (the landed Vault-Transit decrypt-to-scratch object-store over the
Model-B durable MinIO bucket). Forward-only (Standard N): this sprint sits in Phase 7 because it
builds on Sprint `7.14`'s object-store envelope/naming layer in the same durable bucket; it adds the
Tier 1 bootstrap-secret class *alongside* the Tier 2 operational-secret class `7.14` already lands.
**Docs to update**: `documents/engineering/config_doctrine.md` (§0 the canonical three-tier model —
Tier 1 owns the password-gated bootstrap secret), `documents/engineering/vault_doctrine.md`,
`documents/engineering/cluster_federation_doctrine.md` (child-cluster transit-seal: no bundle;
recovery keys in the parent's KV)

### Objective

Move the Vault unlock material — the Shamir unseal keys, recovery keys, and initial root token — off
host disk and into the durable MinIO bucket as the **Tier 1 bootstrap secret**
([config_doctrine.md §0](../documents/engineering/config_doctrine.md)). It is the material that
*unseals* Vault, so it cannot be a Vault-Transit envelope (which would require an unsealed Vault);
instead it is password-AEAD-sealed (Argon2id + ChaCha20-Poly1305) and read via the static bootstrap
MinIO root credential, with the operator password the sole ephemeral secret for decrypting the bundle.
This is the
prodbox-specific additive layer hostbootstrap deliberately does not own — the obfuscated MinIO secret
store plus the sealed-Vault fail-closed posture — layered over the same durable bucket Sprint `7.14`
established. Tier 1 is root-cluster-only: child clusters use transit-seal (no bundle; their recovery
keys live in the parent's KV), per
[cluster_federation_doctrine.md](../documents/engineering/cluster_federation_doctrine.md).

### Deliverables

- The password-AEAD-sealed unlock bundle (Shamir unseal keys + recovery keys + initial root token) is
  written to the durable MinIO bucket under the shared opaque-naming layer, **not** to host disk, and
  **not** as a Vault-Transit envelope.
- The static bootstrap MinIO root credential reads the bundle before Vault is reachable; the bundle is
  sealed with Argon2id key derivation + ChaCha20-Poly1305 AEAD; the operator password is the only
  ephemeral secret in the unseal path.
- The bootstrap reorder this requires — MinIO reachable *before* Vault unseal — is staged, with the
  MinIO-root-decoupling reorder applied **last** so each reorder step is independently provable.
- Child-cluster bring-up keeps the transit-seal path unchanged (no local bundle; recovery keys in the
  parent's KV); Tier 1 applies only to the root cluster.

### Validation

- A live home reconcile/unseal/rebuild proves the relocated bundle unseals Vault from MinIO with the
  operator password and no host-disk unlock material remaining.
- A child-cluster bring-up proves the transit-seal path is untouched (no Tier 1 bundle on the child).

### Remaining Work

- ✅ Landed (code-owned, validated 2026-06-18): the additive dual-write to the MinIO bootstrap object +
  the then-KDF bootstrap MinIO read credential + the prefer-MinIO/fallback-disk unseal read.
  Disk remains PRIMARY this stage; the bundle is now written to **both** disk and MinIO.
- ✅ Landed (code-owned, validated 2026-06-22): the MinIO access credential is now a **single static
  constant** (`Prodbox.Minio.RootCredential`), superseding the 2026-06-21 password-derived approach
  (`deriveMinioRootPassword`/`deriveBootstrapMinioCredential`, now deleted) per the operator decision that
  deriving key/value pairs from a memorized password is security theatre — the real security is Vault
  Transit + the bundle's password-AEAD seal, not the access credential (which only gates ciphertext over a
  localhost NodePort). `secret/minio/root.{rootUser,rootPassword}` are `staticField`s; the unlock-bundle
  dual-write/read use the static root via `bootstrapObjectStoreConfig`. This **fixes the rebuild mismatch**
  (a static credential is trivially stable, so a retained MinIO PV always matches Vault) AND, because the
  static root is a credential MinIO accepts, the Tier-1 bundle now **round-trips through MinIO** —
  **resolving the previously-deferred `InvalidAccessKeyId` axis**. The disk stays the load-bearing
  fallback. Gate: `dev check` 0, derivation tests removed + a static-field/static-config test added, full
  `test unit` 1058/1058.
- None. The disk-free unseal cutover is closed by Sprint `7.25`; historical additive dual-write
  details remain above for traceability.

## Sprint 7.20: Test-Harness IAM Credential Lifecycle Doctrine + Teardown-Completeness Guard ✅

**Status**: ✅ Done (code-owned + doctrine, validated 2026-06-18); 🧪 Live-proof pending (live AWS exercise
of the guard, operator-driven, Standard O). The mint-to-Vault + delete-from-AWS-and-Vault IAM lifecycle was
already shipped; this sprint (1) canonicalized it as doctrine in `aws_admin_credentials.md` +
`aws_integration_environment_doctrine.md` (the earlier docs pass), and (2) added the teardown-completeness
guard in `src/Prodbox/Aws.hs`: a pure `residueFromProbe :: IamProbe -> VaultProbe -> Either ResidueError ()`
classifier (+ `renderResidueError` naming exactly what leaked — the IAM user, the access key IDs, the Vault
cred path) wrapped by `assertOperationalTeardownComplete`, wired into `runAwsIamHarnessTeardown` AFTER
`applyAwsTeardown` (extending, not weakening, the existing `operationalCredentialsCleared` throw). It reuses
`operationalIamUserExists` (`iam:get-user`) + `listOperationalAccessKeyIds` (`iam:list-access-keys`) +
`operationalCredentialsCleared`, and is fail-closed ("cannot observe" ≠ "gone"). The Vault "clear" stays an
empty-value write (a true KV delete of `secret/gateway/gateway/aws` is noted as an optional future
refinement). Gate: `dev check` 0, `test unit` 0 (995, +8 guard tests), `integration cli`/`env` 0 (39/39).
**Blocked by**: Sprint `7.3` (the shared suite-level IAM harness) and Sprint `7.16` (the
`test-secrets.dhall` admin-acquisition split). Both are earlier-or-same-phase landed code (Standard N,
forward-only).
**Live-proof**: pending — the live AWS exercise of the teardown-completeness guard (asserting the IAM
user + keys are gone from AWS and the Vault creds are cleared after a real run) shares the
operator-driven `Live-proof: pending` axis (Standard O).
**Docs to update**: `documents/engineering/aws_admin_credentials.md`,
`documents/engineering/aws_integration_environment_doctrine.md`

### Objective

Canonicalize the already-implemented test-harness IAM credential lifecycle as doctrine and add a
teardown-completeness guard. The lifecycle CODE already exists exactly as intended: the harness drives
`vault init` with the `test-secrets.dhall` password; uses the elevated
`aws_admin_for_test_simulation.*` fixture (the stand-in for the operator's ephemeral elevated CLI
credential) to mint the operational IAM user + keys; writes them **directly to Vault** at
`secret/gateway/gateway/aws` (never to `prodbox-config.dhall`); and on postflight (success, failure,
Ctrl-C, plus preflight idempotency) **deletes the IAM user + keys from AWS** and clears the Vault
creds. The mint-into-Vault + delete-from-AWS-and-Vault path is the Tier 2 operational-secret lifecycle
([config_doctrine.md §0](../documents/engineering/config_doctrine.md)) applied to the harness's
test-simulated admin flow. This sprint marks that code-owned surface ✅ Done and schedules the
doctrine-canonicalization + guard as the new 📋 deliverable.

### Deliverables

- ✅ (already shipped, code-owned) — the suite-level IAM harness mints the operational IAM user + keys
  from the `aws_admin_for_test_simulation.*` fixture into Vault KV (`secret/gateway/gateway/aws`),
  never into `prodbox-config.dhall`, and on every exit path (success / failure / Ctrl-C / preflight
  idempotency) deletes the IAM user + keys from AWS and clears the Vault creds.
- ✅ Canonicalized the lifecycle as doctrine in
  [aws_admin_credentials.md](../documents/engineering/aws_admin_credentials.md) (citing
  [aws_integration_environment_doctrine.md](../documents/engineering/aws_integration_environment_doctrine.md)),
  so the mint-to-Vault + delete-from-AWS-and-Vault contract is the named SSoT for the harness IAM
  lifecycle rather than implementation lore.
- ✅ The teardown-completeness guard landed: `Prodbox.Aws.assertOperationalTeardownComplete` (driven by
  `awsTeardownGuard`) asserts, after a harness run, that the IAM user + keys are gone from AWS and the
  Vault creds are cleared. Recorded nuance: Vault is currently "cleared" by writing empty values, not a
  true KV delete — a true KV delete remains an optional future refinement, not a hard-delete claim.

### Validation

- The doctrine SSoT names the mint-to-Vault + delete-from-AWS-and-Vault lifecycle (no duplication of
  the contract; the engineering docs own it).
- The teardown-completeness guard fails loud if a harness run leaves the IAM user, its access keys, or
  a populated Vault cred behind.

### Remaining Work

- ✅ Landed (2026-06-18): both deliverables — the doctrine canonicalization (earlier docs pass) and the
  teardown-completeness guard (`residueFromProbe` + `assertOperationalTeardownComplete`, wired into
  `runAwsIamHarnessTeardown`, 8 unit tests over the pure classifier + error rendering). The IAM-lifecycle
  code itself was already ✅ Done.
- 🧪 Remaining (Live-proof-pending, Standard O): the live AWS exercise of the guard — a real harness run
  asserting the IAM user + keys are gone from AWS and the Vault cred is cleared. Non-blocking,
  operator-driven (shares the 7.5/7.5.c live-AWS axis).

## Sprint 7.21: Per-Run Pulumi-Destroy Robustness — Corrupt/Absent Checkpoint + MinIO-Secret Handling ✅

**Status**: ✅ Done on the code-owned **residue-observation** surface (validated 2026-06-18). The
destroy-INVOCATION gap this sprint did *not* cover — `destroy<Stack>Status` fetched `pulumi stack output`
and read the in-cluster `minio` k8s secret *before* any residue check, so a 2026-06-18 home `test all`
still RC=1'd at the per-run destroy — is now **closed by Sprint `7.22`** (below), which gates
`destroy<Stack>Status` on this sprint's read-only observation and is live-proven on the home cluster. The
classifier + funnel below remain ✅. A pure
`classifyCheckpointBytes :: Maybe ByteString -> CheckpointObservability`
(`CheckpointAbsent | CheckpointEmpty | CheckpointCorrupt | CheckpointPresent`) in
`src/Prodbox/Pulumi/EncryptedBackend.hs` classifies the per-run stack's observability; the read-only IO
shell `observeStackCheckpoint` (no scratch hydrate / no Pulumi run / no re-store — fixing the old
`doesFileExist`-collapses-empty-into-present bug) feeds `Prodbox.Infra.StackOutputs.observeEncryptedStackCheckpoint`
→ `Prodbox.Lifecycle.LiveResidue.queryOne` (the single per-run residue funnel for the cascade
`reconcileAbsent`, the `aws teardown` gate, and the per-stack residue helpers). Mapping per
[lifecycle_reconciliation_doctrine.md](../documents/engineering/lifecycle_reconciliation_doctrine.md)'s
Soundness invariant: absent/empty → `ResidueAbsent` (SKIP — the home case, per-run AWS stacks never
provisioned); corrupt-non-empty / unreadable-backend → `ResidueUnreachable` (REFUSE with the stack name +
the canonical `prodbox aws stack <stack> destroy --yes` recovery, never a silent skip); valid → destroy.
Fail-closed (only absent/empty skip) and leak-safe (the postflight `clearOperationalCredsAfterPostflight`
credential-preservation is untouched). The home-`test all` `secrets "minio" not found` is eliminated as a
consequence: on home the residue query returns Absent → the destroy (and its k8s-secret read) is skipped.
Gate: `dev check` 0, `test unit` 0 (1025, +16 new), `integration cli`/`env` 0. `aws-ses` (long-lived) is
unchanged (its gate already fails closed). Files: `EncryptedBackend.hs`, `StackOutputs.hs`, `LiveResidue.hs`,
`test/unit/Main.hs`.

**Superseded planned-status note**: The preflight/postflight per-run Pulumi destroy must gracefully handle a
corrupt or empty checkpoint (`unexpected end of JSON input`) and an absent in-cluster MinIO secret,
treating genuinely-absent per-run state as nothing-to-destroy rather than hard-failing the suite. This
defect surfaced on the home `prodbox test all` run *after* the Sprint `1.39` floor fix advanced the
bootstrap past the basics-floor gap, exposing the first per-run destroy attempt against state that no
longer exists or never materialized.
**Blocked by**: Sprint `7.14` (the landed Vault-Transit decrypt-to-scratch Model-B object-store over
the durable MinIO bucket, which owns the per-run checkpoint envelope/read path) and the managed-resource
registry + `reconcileAbsent` reconciler (Phase 4 Sprints `4.20`–`4.22` plus Sprint `7.8`, all landed).
Earlier-or-same-phase landed code (Standard N, forward-only).
**Docs to update**: `documents/engineering/lifecycle_reconciliation_doctrine.md`

### Objective

Make the per-run Pulumi-destroy path classify a corrupt/empty checkpoint and an absent in-cluster MinIO
secret as observation outcomes rather than hard failures, so a per-run stack whose state is genuinely
gone (or never materialized) is reconciled as nothing-to-destroy instead of failing the suite. This is
the [lifecycle_reconciliation_doctrine.md → Soundness invariant](../documents/engineering/lifecycle_reconciliation_doctrine.md)
applied to the per-run destroy: `Unreachable` ("cannot observe") is never silently collapsed to
"absent/clean", but a positively-observed *absent* per-run checkpoint **is** a clean skip. The
distinction is the whole point — a `pulumi destroy` that errors with `unexpected end of JSON input` on a
truncated checkpoint, or that cannot read the in-cluster MinIO secret backing the per-run state, must be
classified deliberately (absent → skip; cannot-observe → refuse) through the managed-resource registry's
`reconcileAbsent` path rather than bubbling a raw subprocess failure up through the harness postflight.

### Deliverables

- The per-run preflight/postflight destroy distinguishes three checkpoint states: positively-present
  (destroy + re-observe), positively-absent / empty (skip as nothing-to-destroy), and unreadable /
  unreachable (refuse, per the Soundness invariant) — rather than letting a corrupt-checkpoint
  `unexpected end of JSON input` or a missing in-cluster MinIO secret hard-fail the suite.
- A corrupt or empty per-run checkpoint is treated as genuinely-absent per-run state (nothing to
  destroy), consistent with
  [lifecycle_reconciliation_doctrine.md](../documents/engineering/lifecycle_reconciliation_doctrine.md)'s
  rule that "cannot observe" is never silently treated as "absent" — and, symmetrically, that a
  positively-observed absent checkpoint is a clean skip, not an error.
- An absent in-cluster MinIO secret backing the per-run state is classified through the same
  registry-driven `discover` → gate-decision combinator (Sprints `4.20`–`4.22`, `7.8`) so the per-run
  `reconcileAbsent` path degrades gracefully instead of throwing a raw subprocess error.
- The home `prodbox test all` postflight no longer fails terminally on a per-run destroy whose state is
  corrupt, empty, or backed by a missing MinIO secret.

### Validation

- A home `prodbox test all` run whose per-run checkpoint is corrupt/empty (or whose in-cluster MinIO
  secret is absent) completes postflight by classifying the per-run state as nothing-to-destroy rather
  than hard-failing the suite.
- A per-run stack whose state is genuinely present still destroys and re-observes; an unreadable /
  unreachable per-run state still refuses (Soundness), proving the classifier did not collapse
  cannot-observe into absent.

### Remaining Work

- ✅ Landed. The corrupt/empty-checkpoint + absent-MinIO-secret classification on the per-run destroy
  path is applied by `LiveResidue.queryOne` → `observeEncryptedStackCheckpoint`
  (ABSENT/EMPTY → `ResidueAbsent` skip; CORRUPT/unreadable → `ResidueUnreachable` refuse) and by the
  destroy-INVOCATION gate `perRunDestroyDecisionFromStatus` (`PerRunDestroySkip`/`Proceed`/`Refuse`,
  consulted by each `destroy<Stack>Status` before any `pulumi`/MinIO-secret access), routed through the
  managed-resource registry's `reconcileAbsent` (`runNativeDeleteCascade`, Sprint `4.21`). **Closed by
  Sprint `7.22`** (which gated the destroy-invocation path + unified the MinIO-creds source — see its
  "closes Sprint `7.21`'s outstanding … proof" note).
- ✅ Live-proven 2026-06-18 (via Sprint `7.22`): the home `prodbox test all` postflight that reproduced
  the `unexpected end of JSON input` hard-failure now converges cleanly (the `aws stack <stack> destroy
  --yes` commands skip cleanly on the home cluster). The former Sprint `7.19` disk-free reorder landed as
  Sprint `7.25` (live-proven 2026-06-23), independently of this sprint.

## Sprint 7.22: Gate the Per-Run Destroy-Invocation Path + Unify Its MinIO-Creds Source ✅

**Status**: ✅ Done on the code-owned surface (validated 2026-06-18); 🧪 Live-proof **MET** for the
destroy-invocation gate — on the home cluster the exact harness commands
`prodbox aws stack {eks,test,aws-subzone} destroy --yes` now each report
`absent (no per-run checkpoint to destroy …)` (RC=0) instead of the prior
`pulumi stack output failed: unexpected end of JSON input` + `secrets "minio" not found` hard-failure.
Surfaced by the 2026-06-18 home `test all` (3rd attempt): Sprint `7.21` gated the residue-observation
*funnel* (`LiveResidue.queryOne`) but the per-run **destroy-invocation** path (`destroy<Stack>Status`)
fetched stack outputs (`pulumi stack output`) and read the in-cluster `minio` k8s secret *before* any
residue check. Root cause refined during the fix: the home cluster's Model-B per-run checkpoints were
**already absent** (home never provisions per-run AWS stacks) — the crash was the ungated destroy diving
into the k8s-secret + legacy `pulumi stack export` path *without first observing* the Model-B residue, not
a corrupt Model-B object. The gate observes Model-B first → absent → skip, short-circuiting before either
failing path.
**Blocked by**: Sprint `7.21` (the landed `classifyCheckpointBytes` classifier + `observeStackCheckpoint`)
and Sprint `7.14` (the Model-B object store). Forward-only.
**Docs**: [lifecycle_reconciliation_doctrine.md § 3.2](../documents/engineering/lifecycle_reconciliation_doctrine.md)

### Objective

Make the preflight/postflight per-run destroy-INVOCATION path
(`Prodbox.Lifecycle.ResourceRegistry.reconcileAbsent` → `Prodbox.Infra.AwsEksTestStack.destroyAwsEksTestStack`
and the sibling subzone/test destroys) consult the Sprint `7.21` `classifyCheckpointBytes` /
`observeStackCheckpoint` BEFORE running `pulumi destroy` / `pulumi stack output`, so a corrupt/empty/absent
checkpoint never reaches a crashing `pulumi` invocation. Per
[lifecycle_reconciliation_doctrine.md](../documents/engineering/lifecycle_reconciliation_doctrine.md): absent
/ empty → skip; corrupt-non-empty / unreadable → **clean refuse** (actionable error + recovery path), never a
crashing `pulumi destroy`. Also unify the destroy path's MinIO-creds source onto the Vault `secret/minio/root`
the observation path uses (instead of `Infra.MinioBackend.readMinioCredentials`'s in-cluster `minio` k8s
secret, which is absent on a home cluster that never provisioned the per-run stacks).

### Deliverables

- ✅ The per-run destroy-invocation path is gated by the read-only observation first, via the pure
  `LiveResidue.perRunDestroyDecisionFromStatus` wired into `destroy{AwsEksTest,AwsTest,AwsEksSubzone}StackStatus`:
  absent/empty → `PerRunDestroySkip` (return success, never touch `pulumi`/the `minio` secret); present →
  `PerRunDestroyProceed` (the existing destroy body); corrupt/unreachable → `PerRunDestroyRefuse`
  (clean, actionable refusal naming the prune recovery — no `pulumi destroy` crash).
- ✅ The gate (and the residue observation it reuses) resolves MinIO creds from Vault `secret/minio/root`,
  not the in-cluster `minio` k8s secret — so the home `secrets "minio" not found` failure mode is
  eliminated (the absent case skips before the legacy k8s-secret read is ever reached).
- ✅ Prune affordance: `prodbox aws stack {eks,test,aws-subzone} prune-corrupt-checkpoint --yes`
  (`LiveResidue.pruneCorruptPerRunCheckpoint` → `EncryptedBackend.pruneLogicalPulumiStack`) clears a
  genuinely-corrupt/empty Model-B checkpoint, refuses to prune a `Present` one or an unobservable backend,
  and is idempotent on an already-absent one. Chosen mechanism: a **named per-run leaf** (not a `--force`
  flag — prodbox forbids `--force` escape hatches), per-run stacks only.

### Validation

- ✅ Unit (3 new, +1 parser, +1 Parser.hs roundtrip arm): `perRunDestroyDecisionFromStatus` skips on
  absent, proceeds on present, refuses on unreachable (message names the prune recovery); the
  `prune-corrupt-checkpoint` leaf parses for eks/test. Full gate: `dev check` 0, `test unit` 1034/1034,
  `integration cli`/`env` 0, CLI goldens regenerated (3 per-run leaves, not aws-ses).
- ✅ Live-proof (2026-06-18, home cluster, Vault unsealed): the exact harness commands
  `prodbox aws stack {aws-subzone,eks,test} destroy --yes` each return RC=0 with
  `absent (no per-run checkpoint to destroy …)` — the prior `unexpected end of JSON input` +
  `secrets "minio" not found` hard-failure is gone. `prune-corrupt-checkpoint --yes` confirmed Model-B
  absent (idempotent no-op) on all three.
- 🧪 Live-proof (end-to-end, in flight): a full home `prodbox test all` proceeding past the
  preflight/postflight per-run destroy into the validation suites.

### Remaining Work

- ✅ Landed (2026-06-18): the gate, the Vault-creds-sourced observation, and the `prune-corrupt-checkpoint`
  recovery leaf. This closes Sprint `7.21`'s outstanding live home-`test all` preflight/postflight proof —
  the per-run destroy-invocation path no longer hard-fails on an absent (or corrupt) checkpoint or an absent
  in-cluster `minio` secret. No leftover corrupt Model-B checkpoints existed on the home cluster (the crash
  was the ungated path, not corrupt state); the prune leaf remains the doctrine-clean recovery for any future
  genuinely-corrupt checkpoint.
- 🧪 Remaining (Live-proof-pending, non-blocking, Standard O): the full home `prodbox test all` end-to-end
  pass through the validation suites (in flight at close).

## Sprint 7.23: `aws-ses` Encrypted-Backend Reconcile Recovery (Five Stacked Bugs) ✅

**Status**: ✅ Done on the code-owned surface + live-proven for the `aws-ses` reconcile (2026-06-18); 🧪
home `prodbox test all` end-to-end pass is the remaining live axis (in flight at close). Surfaced by the home
`test all` *after* Sprint `7.22` unblocked the preflight per-run destroy: the run reached **Phase 1.6
"restoring supported runtime"** and RC=1'd at `Supported runtime bootstrap: syncing Keycloak SMTP Secret from
aws-ses` — `pulumi stack output failed: ... failed to load checkpoint: unexpected end of JSON input` —
**before any named validation ran**. NOT a `7.22` regression. The preflight crash had masked this on every
prior attempt. The `aws-ses` encrypted Model-B reconcile path had **never run end-to-end on current pulumi
(v3.228)**; repairing it required fixing five stacked bugs.

**Verified diagnosis (read-only AWS prechecks + S3/Model-B inspection, 2026-06-18):** the `aws-ses` data was
HEALTHY (durable Pulumi state in the long-lived S3 backend; SES domain + DKIM verified; rule set active;
capture bucket + SMTP user live). The empty/garbage object the runtime tripped on was the **Model-B MinIO**
working-copy, which on this fresh-MinIO cluster held a stale `pulumi stack export`-format blob. Operator
steer (2026-06-18): destroying `aws-ses` test/dev data is acceptable; priority is the new config shape
working — so the stale S3 state + Model-B object were cleared and `aws-ses` re-imported from live resources.

**The five fixes (all ✅ landed 2026-06-18):**

1. **Scratch-backend passphrase.** `EncryptedBackend.fileBackendEnvironment` *stripped*
   `PULUMI_CONFIG_PASSPHRASE`; `aws-ses` (the only stack with a committed `encryptionsalt`) died with
   `get stack secrets manager: passphrase must be set`. Now the scratch env *sets* `PULUMI_CONFIG_PASSPHRASE
   = ""` (strip any inherited value, then set empty); per-run stacks (no salt) ignore it.
2. **Hydrate-path fallback on an unusable Model-B object.** Split the load: the OBSERVE path
   (`loadEncryptedOrLegacyCheckpoint`, feeding the Sprint `7.21` residue gate) classifies the RAW bytes
   (Empty/Corrupt/Present — no fallback), while the HYDRATE path (`loadHydratableCheckpoint`, used by
   `withDecryptedStackWith`) falls back to the legacy backend when the Model-B object is **not a usable
   on-disk checkpoint** (`checkpointBytesUsable`): blank, corrupt/truncated, OR in the `pulumi stack export`
   wire format (`{deployment}`) rather than the file-backend on-disk format (`{checkpoint}`). Raw-hydrating
   a foreign-format object made pulumi report `failed to load checkpoint: unexpected end of JSON input`. The
   fix recovers the real state from legacy and self-heals Model-B on the next `collectScratchCheckpoint`
   re-store.
3. **Invalid `--secrets-provider plaintext`.** `pulumiStackSelect --create` passed `plaintext`, which pulumi
   v3.228 rejects (`open secrets.Keeper: no scheme in URL "plaintext"`). Now `passphrase`, matching the
   committed `encryptionsalt` + the empty passphrase; at-rest secrecy is the Model-B Vault-Transit envelope.
4. **State-recovery probes had no AWS creds.** `recoverAwsSesPulumiStateFromLiveResources` probed live AWS
   (`aws` CLI), `pulumi import`-ed, and rotated the SMTP key all using the scratch env — whose standard
   `AWS_*` creds are stripped by `fileBackendEnvironment` — so every probe failed, nothing was imported, and
   `pulumi up` tried to CREATE already-live resources (`EntityAlreadyExists` / `AlreadyExists` /
   `BucketAlreadyOwnedByYou`). New `awsCliCredsFromProviderEnv` re-derives `AWS_*` from the surviving
   `PRODBOX_PULUMI_AWS_*` provider creds.
5. **Durable-S3 / stale-state semantics (operator-resolved).** The migrate path deletes the legacy (S3)
   state on success; per the operator steer this is acceptable for test/dev. The stale S3 `aws-ses` state and
   the export-format / partial Model-B objects were cleared (S3 objects deleted directly under the operator's
   destroy authorization; the Model-B object self-cleared via the failed-attempt collect-delete), so a clean
   reconcile re-imports the live resources.

**Live-proof (home cluster, 2026-06-18):** `prodbox aws stack aws-ses reconcile` completes — imports the
live capture bucket / SMTP user / receipt rule set / rule, rotates the stale SMTP key, idempotent-creates the
rest (domain identity + DKIM verify no-op, active-rule-set no-op, route53 upsert), re-stores a valid on-disk
Model-B checkpoint; a second run reports **17 unchanged, RC=0** (idempotent). Read-only prechecks confirmed
the `pulumi up` creates are idempotent (verified domain/DKIM, active rule set, route53 overwrite, ≤2 IAM keys).

**Blocked by**: none in-code (forward-only; builds on `7.14`/`7.21`).
**Docs**: [lifecycle_reconciliation_doctrine.md § 3.2](../documents/engineering/lifecycle_reconciliation_doctrine.md),
[phase-8-email-invite-auth.md](phase-8-email-invite-auth.md) (owns the `aws-ses` + `keycloak-smtp` flow).

### Deliverables

- ✅ Five fixes above (`EncryptedBackend.fileBackendEnvironment` passphrase; `loadHydratableCheckpoint` /
  `checkpointBytesUsable` hydrate-fallback incl. export-format rejection, kept distinct from the raw observe
  load; `AwsSesStack.pulumiStackSelect` `passphrase` provider; `awsCliCredsFromProviderEnv` for state
  recovery; stale-state clearing).
- ✅ The `aws-ses` reconcile is idempotent and round-trips a valid on-disk Model-B checkpoint.

### Validation

- ✅ Unit 1034/1034 (incl. the `fileBackendEnvironment` `PULUMI_CONFIG_PASSPHRASE = ""` assertion and a
  realistic on-disk-format hydrate stub), `dev check` 0, integration cli/env 0.
- ✅ Live: `prodbox aws stack aws-ses reconcile` → import-before-up adopts live resources, RC=0; re-run 17
  unchanged.
- 🧪 Remaining: a home `prodbox test all` clears Phase 1.6 and proceeds into the named validation suites
  (Phase 2/2) now that the SMTP-sync reads a valid `aws-ses` Model-B checkpoint.

### Remaining Work

- ✅ All five fixes + the live `aws-ses` reconcile proof landed 2026-06-18.
- 🧪 Home `prodbox test all` end-to-end pass (Live-proof-pending, Standard O). The one-time SMTP access-key
  rotation that any successful reconcile triggers is an expected, documented side effect.

## Sprint 7.24: Preflight Fail-Closed Gate — IAM-User-Gated Refinement of the Vault-Backed aws-config Observation ✅

**Status**: Done (code-owned surface) — live-surfaced 2026-06-20 by the first two `prodbox test all` runs
**Implementation**: `src/Prodbox/Aws.hs` (`refineAwsConfigResidueAgainstIamUser` wired into `discoverOperationalResidue` — the teardown **gate**; `operationalCredentialsClearedAtPreflight` + the pure `operationalCredentialsClearedDecision` for the preflight cleared-**verification**), `src/Prodbox/TestRunner.hs` (the harness-lifecycle **reorder** — `harnessNeedsVaultBeforeSetup` + a bare pre-`cluster reconcile` for cluster-bootstrapping suites), `test/unit/Main.hs`
**Blocked by**: none (refines Phase 7's own AWS IAM-harness teardown surface; forward-only)
**Live-proof**: pending — a clean-machine `prodbox test all` whose AWS IAM harness preflight now clears and proceeds into cluster bring-up
**Independent Validation**: the refinement is a pure function with a four-case truth-table unit test (downgrade only when the IAM user is confirmed absent; fail-closed preserved when the user is present or itself unreachable, and when the aws-config is present); validated on the code-owned surface with no dependency on a later phase.
**Docs to update**: `documents/engineering/lifecycle_reconciliation_doctrine.md` (§3.1 invariant 2).

### Objective

The first live `prodbox test all` surfaced the exact gap Sprint `7.14`'s "🧪 Live-proof pending" note
flagged: after `7.14` migrated the operational `aws.*` credential to a mandatory `SecretRef.Vault`,
the AWS IAM-harness **preflight** teardown-refresh observes `operational-aws-config` by resolving that
reference **from host Vault** (`discoverOperationalResidue` → `resolveAwsCredentialsRefFromHostVault`).
At preflight the cluster — and therefore Vault at `127.0.0.1:31820` — is not up yet, so the resolve
returns a connection error, classified `ResidueUnreachable`, and the fail-closed gate
([lifecycle_reconciliation_doctrine.md §3.1](../documents/engineering/lifecycle_reconciliation_doctrine.md))
refuses — aborting **every** `test all` on a clean machine. AWS is reachable, the admin credential
authenticates with `AdministratorAccess`, and no operational IAM user is stranded; the refusal is
purely the Vault-at-preflight catch-22.

### Deliverables

- `refineAwsConfigResidueAgainstIamUser :: ResidueStatus -> ResidueStatus -> ResidueStatus`: a pure
  cross-resource refinement that downgrades a `ResidueUnreachable` `operational-aws-config` to
  `ResidueAbsent` **only when** the `operational-iam-user` residue is `ResidueAbsent` (the user is
  observed gone via the admin credential, which is independent of Vault). Every other case preserves
  the raw status, so the gate still fails closed.
- Wired into `discoverOperationalResidue` so the preflight teardown-refresh no longer deadlocks on a
  Vault that only comes up later in the same run.
- The SAME Vault-at-preflight flaw lived a second layer down in the harness setup's post-cleanup
  **verification** (`operationalCredentialsCleared` also resolves the aws.* `SecretRef` from Vault).
  `operationalCredentialsClearedAtPreflight` applies the identical IAM-user-gated principle for the
  preflight call only; the two postflight teardown guards keep the strict check, since they run after
  the cluster lifecycle when Vault is up (a justified asymmetry — preflight may precede Vault's
  existence, postflight always follows it).
- The doctrine §3.1 "Soundness" invariant gains a "Dependent-resource refinement" paragraph stating
  this is keyed on the authoritative, Vault-independent observation of the safety-critical resource —
  **not** a relaxation of `Unreachable → refuse`.
- **The lifecycle reorder (part 3).** Once both observation layers cleared, the harness setup reached
  its actual **mint + Vault-write** (`applyAwsSetupWithFederatedFallback` writes operational `aws.*`
  into Vault; `seedAcmeEabFromTestSecrets` writes the ACME EAB) — which still failed because the
  harness setup runs *before* the suite body's `cluster reconcile` brings Vault up. Root cause: Sprint
  `7.14` moved that write from the local `prodbox.dhall` to Vault but never live-proved the ordering.
  Fix: for cluster-bootstrapping suites (`harnessNeedsVaultBeforeSetup = nativeRequiresSupportedRuntimeBootstrap`),
  `runNativeSuite` runs a **bare `cluster reconcile`** first — which brings Vault up and skips the
  gateway/edge chart cleanly while `aws.*` is unmaterialized (`Rke2.hs` operational-credential-gate
  skip) — *then* the harness setup materializes `aws.*` + EAB into Vault (host root-token write
  fallback, since the gateway SA is not up after a bare reconcile), *then* the body's existing
  `--with-edge` reconcile + gateway/api/websocket charts run with `aws.*` present. Pure harness-only
  suites (`aws-iam`, `dns-aws`) do **not** bootstrap a cluster and get no pre-reconcile. The bare and
  `--with-edge` reconciles are idempotent (both `applyNativeInstallPlan`).

### Validation

`prodbox dev check` 0; the four-case refine truth-table unit test green; full `test unit` green.

### Remaining Work

- 🧪 Live-proof (non-blocking, Standard O): the resumed `prodbox test all` clears preflight and proceeds.

## Sprint 7.25: Disk-free Vault unseal — unlock bundle MinIO-only ✅

**Status**: ✅ Done + **live-proven 2026-06-23**. A fresh `.data/`-wiped `cluster reconcile` brought MinIO
up FIRST (cluster-only, static cred), then Vault init **wrote the unlock bundle to the durable MinIO
bucket** ("verified by decrypting the read-back") and unseal **read it FROM MinIO** — with **no
`.data/prodbox/vault-unlock-bundle.age` on host disk** and the `.cluster-established` marker stamped; no
`MinIO unreachable`, no `InvalidAccessKeyId`, no test-seam (production used real MinIO). `cluster
reconcile` RC=0. The disk-free init/unseal/rotate LOGIC is additionally pinned by the `Sprint 1.36 vault
lifecycle` integration test (real `vault init`/`unseal`/`reconcile`/`rotate` against the bundle store).
**Implementation (landed)**: `charts/minio/templates/statefulset.yaml` + `charts/minio/values.yaml`,
`src/Prodbox/CLI/Rke2.hs` (`renderMinioChartArgs`, `applyNativeInstallPlan` reorder, removed the
restart-on-change + `VaultLifecycleResult.vaultLifecycleMinioRootChanged`), `src/Prodbox/CLI/Vault.hs`
(`initFreshVault`, `writeBootstrapBundleToMinio`, rotate), `src/Prodbox/Vault/Host.hs`
(`loadAndDecryptBundle` MinIO-only + `fetchBootstrapBundleEnvelope`), `src/Prodbox/Vault/Orchestration.hs`
(`vaultUnlockBundlePath` → non-secret `clusterEstablishedMarkerPath`), `src/Prodbox/Settings.hs`,
`test/unit/Main.hs`; docs in `vault_doctrine.md` §6/§6.1 + `config_doctrine.md` §0 Tier 1.
**Blocked by**: none (refines Phase 7's own Tier-1 unlock-bundle surface). **Closes Sprint `7.19`'s
deferred 🧪 disk-free-cutover axis** — unblocked by the 2026-06-22 static MinIO credential (the
unlock-bundle write/read now uses a credential MinIO accepts, and MinIO no longer needs Vault for its
root credential).
**Independent Validation**: unit-testable (chart-args inject the static root cred; MinIO-only read has
no disk-fallback branch) + a live home wipe-and-rebuild; no dependency on a later phase.
**Docs to update**: `vault_doctrine.md` §6/§6.1, `config_doctrine.md` §0 Tier 1, `system-components.md`.

### Objective

Make the host's local disk hold NO material that can unseal Vault: the Tier-1 unlock bundle lives ONLY
in the durable MinIO bucket. The previously-cited risk (MinIO unreachable at unseal → no disk fallback
→ brick) is removed by the precondition that **MinIO depends on nothing but the cluster** — so MinIO is
down only when the cluster is down, in which case there is nothing to unseal anyway. The host-disk copy
guarded against "MinIO fails independently," which can no longer happen.

### Deliverables (landed)

- ✅ **A — cluster-only MinIO.** Deleted the `charts/minio` `vault-secrets` init container + the
  `vault-materialized` tmpfs volume + the `vault.*` values (its sole Vault dependency at startup). The
  MinIO container takes `MINIO_ROOT_USER`/`MINIO_ROOT_PASSWORD` directly from `.Values.rootUser`/
  `rootPassword`, injected by `renderMinioChartArgs` `--set` from `Prodbox.Minio.RootCredential` (single
  source of truth; non-secret constant, like Harbor). MinIO then depends only on the cluster + retained
  PV. `secret/minio/root` stays in Vault for the post-startup gateway/Harbor bootstrap Jobs.
- ✅ **B — reorder.** `applyNativeInstallPlan` brings `ensureMinioRuntime` (`MinioBootstrapPublic`) up
  after `ensureRetainedLocalStorage` and BEFORE `ensureVaultRuntime`/the Vault lifecycle, so Vault init
  writes the bundle to a live MinIO. Removed `restartMinioIfVaultRootChanged` + the now-dead
  `vaultLifecycleMinioRootChanged`/`reconcileStepsMinioRootChanged` (the static cred never changes).
- ✅ **C — disk-free bundle.** `initFreshVault` drops the host-disk write and makes the MinIO write
  REQUIRED (init fails loudly if it fails — no disk fallback); `loadAndDecryptBundle` reads MinIO-only
  (dropped `loadAndDecryptDiskBundle` + the `BootstrapFallBackToDisk`/`classifyBootstrapMinioSource`
  classifier); `rotate-unlock-bundle` writes to MinIO. The bundle stays password-AEAD-sealed; Vault
  Transit unchanged.
- ✅ **Establishment probe + test seam.** The config loader's "established" signal moved off the former
  on-disk bundle to a NON-SECRET `clusterEstablishedMarkerPath` (`.data/prodbox/.cluster-established`,
  stamped at init) so the seed-vs-in-force decision stays port-forward-free
  (`Prodbox.Settings.loadConfigForSettingsWith`). A `PRODBOX_TEST_BOOTSTRAP_BUNDLE_DIR` test seam
  (mirroring the existing `PRODBOX_TEST_*` Vault seams) backs the bundle with a local file so the
  host-only `vault lifecycle` integration test exercises init/unseal/rotate without a cluster MinIO;
  production never sets it.
- ✅ **No-fallback Tier-0 + `config generate` (operator-directed 2026-06-23).** Removed the
  `defaultProjectConfig` synthesis from `writeTier0FloorPreservingParameters` (the `vault init` floor
  stamp): it now **fails fast** when `prodbox.dhall` is absent rather than inventing a default
  (`config_doctrine.md §0`). The binary-generated, non-secret Tier-0 file is instead produced by the new
  **`prodbox config generate`** command (`Native.runConfigCommand`) — non-interactive, idempotent, renders
  `prodbox.dhall` from `defaultConfigFile` when absent — which the test harness and headless bring-up use
  in place of the removed fallback (and which authored the `prodbox.dhall` for the live proof below).

### Accepted edge

Wiping the MinIO PV while RETAINING Vault loses the only unseal source (the disk copy previously covered
it). This is out of the durability model — MinIO's PV holds the in-force config + Pulumi backends too, so
you wipe both together (→ fresh init re-writes the bundle to MinIO) or neither. Recorded in
[vault_doctrine.md §6.1](../documents/engineering/vault_doctrine.md#61-bootstrap-minio-credential).

### Validation

- ✅ `prodbox dev check` 0 (policy + fourmolu + hlint "No hints" + warning-clean build).
- ✅ `prodbox test unit` — 1053/1053 (incl. the rewritten chart-structure test asserting NO
  `vault-secrets` init container + the static `MINIO_ROOT_USER`/`PASSWORD`, and the `renderMinioChartArgs`
  static-cred injection; the `clusterEstablishedMarkerRelPath` + established-probe tests).
- ✅ `prodbox test integration cli` — the `Sprint 1.36 vault lifecycle` test (real `vault init` →
  `unseal` → `reconcile` → `rotate` → `pki` → `seal` against a fake Vault + the disk-free bundle store)
  PASSES, proving the MinIO-only init/unseal/rotate round-trip.
- ✅ **Live wipe-rebuild proof (2026-06-23).** `config generate` authored `prodbox.dhall`; a `.data/`-wiped
  `cluster reconcile` came up RC=0 with MinIO FIRST, the bundle **written to + read from the durable MinIO
  bucket** (verified by read-back), **no `.data/prodbox/vault-unlock-bundle.age` on disk** (`absent`), the
  `.cluster-established` marker present, and no `MinIO unreachable`/`InvalidAccessKeyId`/test-seam — the
  real-MinIO disk-free path end to end.

### Remaining Work

- None — code-owned + live-proven. The
  [legacy-tracking-for-deletion.md → Completed](legacy-tracking-for-deletion.md) rows (host-disk bundle,
  MinIO chart Vault init container, restart-on-change) landed under this sprint.

## Sprint 7.26: Cascade Postflight Tag Sweep — Carve Out Retained Long-Lived Shared Infra ✅

**Status**: ✅ Done (code-owned + unit-validated 2026-06-23). Operator-reported: `cluster delete
--cascade --yes` printed a postflight tag-sweep "operator action required / manual cleanup required"
refusal naming `arn:aws:s3:::prodbox-pulumi-state-long-lived` — the long-lived `pulumi_state_backend`
bucket, which `cluster delete` (even `--cascade`) **retains by design** (destroyed only by `prodbox
nuke`). The bucket surviving was correct; the sweep flagging it was a false positive.
**Implementation**: `src/Prodbox/Lifecycle/TagSweep.hs`, `src/Prodbox/CLI/Rke2.hs`, `test/unit/Main.hs`.
**Blocked by**: none (refines the Sprint `4.11`/`4.17` postflight tag-sweep doctrine, see
[lifecycle_reconciliation_doctrine.md](../documents/engineering/lifecycle_reconciliation_doctrine.md) §6
+ the Resource Lifecycle Classes in [substrates.md](substrates.md)).
**Independent Validation**: pure `partitionRetainedLongLived` is unit-tested; no later-phase dependency.

### Root cause

`runCascadePostflightTagSweep` queried every `prodbox.io/managed-by=prodbox`-tagged resource and refused
on ANY hit, with **no carve-out** for the intentionally-retained long-lived classes — even though the
lifecycle doctrine has the harness carve those same resources out of postflight auto-destroy. (It was a
best-effort step, so the command still exited 0; the teardown succeeded — it was a misleading message,
not a failed teardown.)

### Deliverables

- ✅ `TaggedResource` now carries the matched tag **value** (`taggedResourceMatchedTagValue`), captured
  by `parseTagSweepPayload`.
- ✅ Pure `partitionRetainedLongLived :: [TaggedResource] -> ([retained], [escaped])` keyed on
  `longLivedRetentionMarkers` — `prodbox.io/role=long-lived-pulumi-state` (the `pulumi_state_backend`
  bucket) and `prodbox.io/substrate=shared` (`aws-ses`). A resource (by ARN) is retained when ANY of its
  tag rows is a marker; an escapee that merely shares a common tag (`prodbox.io/managed-by`) with a
  retained resource is still classified escaped.
- ✅ `runCascadePostflightTagSweep` refuses ONLY on `escaped`, reports `retained` as
  "intentionally-retained long-lived resource(s) left in place by design (destroyed only by `prodbox
  nuke`)", and is clean when only retained resources remain. `prodbox nuke`'s own step-4 sweep does NOT
  use the carve-out (it exists to destroy these resources) — unchanged.

### Validation

- ✅ `prodbox dev check` 0; `prodbox test unit` (added: state-bucket carve-out, `aws-ses` carve-out,
  genuine-escapee still-refused, mixed → refuse-only-the-stray-and-not-the-bucket).
- 🧪 Live (non-blocking, Standard O): a `cluster delete --cascade --yes` with the long-lived bucket
  present now reports it as retained-by-design and exits clean instead of demanding manual cleanup.

## Sprint 7.27: Spot-Price Economics on the AWS Substrate [✅ Done]

**Status**: ✅ Done on code-owned surface 2026-07-03; 🧪 Live-proof pending for an actual AWS EC2
spot-price API observation.
**Implementation**: `src/Prodbox/Aws.hs` (the live spot-market price observer over the
credential-region projection plus pure output/payload translation), `src/Prodbox/Scaling/Spot.hs`
(the `SpotPriceThreshold` gate, substrate applicability fold, and three-valued `SpotObservation` →
`SpotDecision` admit/defer/refuse decision), `test/unit/Main.hs`
**Blocked by**: none — Sprint `4.34` is closed, so the spot-economics gate now plugs into the
landed autoscaler/placement surface.
**Live-proof**: pending
**Independent Validation**: unit tests over the pure `admitSpotDeploy` decision — `SpotObserved`
below/at-or-above threshold → admit/defer, `SpotUnobservable` → refuse — plus AWS payload/output
translation tests and `prodbox test integration cli`/`env` on the home/local substrate, where the
gate is a no-op because home-local carries no AWS spot market; no later-phase dependency.

### Objective

Add spot-price observation and threshold gating on the managed-cloud (EKS) substrate per
[resource_scaling_doctrine.md § 4](../documents/engineering/resource_scaling_doctrine.md#4-the-spot-price-gate-managed-cloud-only):
a spot-elastic workload deploys or moves onto spot capacity **only when the observed price is below
its per-workload threshold**, and "cannot observe the price" refuses rather than deploying anyway —
the `Unreachable → refuse` soundness rule applied to placement economics.

### Deliverables

- A live spot-market price observer keyed on the credential region (the region projected by
  `src/Prodbox/AwsEnvironment.hs`, never a separate flag), meaningful only on `SubstrateAws`.
- The `SpotObservation` type is three-valued (`SpotObserved UsdPerHour` / `SpotUnobservable
  UnobservableReason`), mirroring `src/Prodbox/Lifecycle/ResidueStatus.hs`'s
  `ResidueAbsent | ResiduePresent | ResidueUnreachable` discipline.
- `admitSpotDeploy :: SpotPriceThreshold -> SpotObservation -> SpotDecision` admits below-threshold,
  defers at-or-above-threshold, and **refuses** on `SpotUnobservable` — never a silent "deploy
  anyway".
- `spotGateForScalingPolicy` makes the gate applicable only for `SubstrateAws` +
  `ScalingPolicyElastic` plus a threshold witness; home-local and fixed policies are structural
  no-ops.

### Validation

1. `cabal build --builddir=.build all --ghc-options=-Werror`
2. `./.build/prodbox test unit` (1153/1153, including the pure
   `admitSpotDeploy` admit/defer/refuse decision table and AWS payload/output translation tests)
3. `./.build/prodbox dev lint haskell --write`
4. `./.build/prodbox test integration cli` (39/39)
5. `./.build/prodbox test integration env` (39/39)
6. `./.build/prodbox dev docs generate`
7. `./.build/prodbox dev docs check`
8. `git diff --check`
9. `./.build/prodbox dev check`
10. Fail-closed proof: `SpotUnobservable` yields `SpotRefuse`, never `SpotAdmit`.

### Remaining Work

- None for the code-owned surface. The live EC2 spot-price API proof remains a non-blocking
  live-infra axis.

## Sprint 7.28: Static Pre-Created EBS as Retain PVs on EKS [✅ Done]

**Status**: ✅ Done on code-owned surface 2026-07-03; 🧪 Live-proof pending for the destructive
AWS `eks-volume-rebind` parity run.
**Implementation**: `src/Prodbox/Lib/Storage.hs` (CSI PV volume-source renderer + AZ
`nodeAffinity`), `src/Prodbox/Lifecycle/EbsVolume.hs` (retained, PV-tagged EBS
discover/create/wait + static binding projection), `src/Prodbox/Lib/ChartPlatform.hs` (static EBS
storage dispatch on `SubstrateAws`; two-substrate no-provisioner guard in
`buildChartDeploymentPlanPure`), `src/Prodbox/Lib/AwsSubstratePlatform.hs` (MinIO/Vault retained
EBS PV bootstrap before MinIO), `src/Prodbox/CLI/Rke2.hs` (AWS retained inventory capacity and
manual MinIO class), and `pulumi/aws-eks/Main.yaml` (node placement + retained-EBS AZ output).
**Blocked by**: none — extends the home static-`Retain` model of Sprints `3.1`/`4.31` onto EKS; the
EBS managed-resource class it provisions through (Sprint `4.39`) is scheduled forward, not a
backward block (Standard N).
**Live-proof**: pending
**Independent Validation**: pure unit tests over the CSI PV renderer (`claimRef`, `Retain`, CSI
`volumeHandle`, `topology.ebs.csi.aws.com/zone` affinity), retained-EBS create/discover/binding
helpers, AWS snapshot AZ output, substrate storage-class selection, MinIO capacity selection, and
platform ordering. Live-EKS rebinding proof is Phase 5 Sprint `5.12` suite content on the AWS
substrate, tracked as a non-blocking parity axis in [substrates.md](substrates.md) (Standards N/O).
**Docs to update**: `storage_lifecycle_doctrine.md`, `cluster_topology_doctrine.md`,
`helm_chart_platform_doctrine.md`, `substrates.md`, `system-components.md`.

### Objective

Unify block storage across substrates: EKS uses the same static, no-provisioner, `Retain`,
`claimRef`-bound PV model as the home substrate, differing only in the PV volume source — a
**pre-created EBS volume lifted in as a static PV** via the EBS CSI `volumeHandle`, AZ-pinned —
replacing the dynamic `gp2` provisioning of Sprint `7.5.c.i`. Satisfies the "no dynamic
provisioning anywhere" invariant of
[cluster_topology_doctrine.md § 4](../documents/engineering/cluster_topology_doctrine.md) and the
unified-storage doctrine of
[storage_lifecycle_doctrine.md § 1](../documents/engineering/storage_lifecycle_doctrine.md).

### Deliverables

- A CSI PV volume-source variant in `src/Prodbox/Lib/Storage.hs`
  (`spec.csi.driver=ebs.csi.aws.com`, `volumeHandle=<vol-id>`, `Retain`, `claimRef` to the
  deterministic PVC, `topology.ebs.csi.aws.com/zone` `nodeAffinity`), reusing the existing
  deterministic PV/PVC naming (`prodbox-retained-<namespace>-<statefulset>-<ordinal>`).
- `ensureChartStorage` renders a static PV + static PVC (`spec.volumeName` set) on `SubstrateAws`,
  and the no-dynamic-provisioner guard applies to both substrates rather than home-only.
- Durable EBS volumes (MinIO 20Gi, Vault 1Gi, keycloak-postgres/Patroni 20Gi, vscode 50Gi)
  provisioned out-of-band through the Phase 4 registry path (Sprint `4.39`) in a single AZ
  (`AZ[0]`), with `{volumeHandle, availabilityZone}` resolved into the PV renderer; the EKS
  nodegroup keeps a node in that AZ.
- The dynamic `gp2` path (`awsChartStorageClassName`, `chartDynamicStorageManifest` AWS usage) is
  removed and the row is moved to
  [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md) Completed.

### Validation

1. `cabal build --builddir=.build all --ghc-options=-Werror`
2. `./.build/prodbox test unit` (1143/1143; CSI PV renderer + retained-EBS helpers + storage-class
   selection + AWS platform ordering)
3. `./.build/prodbox dev lint haskell --write`
4. `./.build/prodbox dev docs generate`
5. `./.build/prodbox dev docs check`
6. `./.build/prodbox test integration cli` (39/39)
7. `./.build/prodbox test integration env` (39/39)
8. `git diff --check`
9. `./.build/prodbox dev check`

### Remaining Work

- Code-owned work closed. Remaining 🧪 Live-proof: run
  `./.build/prodbox test integration eks-volume-rebind --substrate aws` against a live AWS substrate
  to prove PV/PVC/`volumeHandle` rebinding and sentinel preservation end-to-end.

## Sprint 7.29: EKS VPC Ownership Hardening + Always-Fresh Test VPC [✅ Done]

**Status**: ✅ Done on code-owned surface 2026-07-03; 🧪 live-proof pending for the next real
AWS-substrate provision/destroy cycle.
**Implementation**: `pulumi/aws-eks/Main.yaml` (`prodbox.io/managed-by=prodbox` tags on the
VPC/IGW/route-table/subnets), `src/Prodbox/Infra/AwsEksTestStack.hs` (fresh-VPC guarantee via the
existing destroy-before-ensure residue purge), `src/Prodbox/Lifecycle/TagSweep.hs` (VPC-scoped
escapee classification), and `test/unit/Main.hs` (Pulumi tag coverage + VPC-scoped escapee unit
proof).
**Blocked by**: none.
**Live-proof**: pending
**Independent Validation**: unit/`dev check` over the tag set and the tag-sweep classification of a
VPC-scoped escapee; the always-fresh-VPC guarantee is exercised by the existing per-run
destroy-before-ensure path. No later-phase dependency.
**Docs to update**: `substrates.md`, `system-components.md`, `README.md` (root),
`storage_lifecycle_doctrine.md` (cross-reference only).

### Objective

Make EKS VPC ownership explicit and leak-safe. prodbox already creates its own self-contained VPC
(`10.91.0.0/16`, never the account default); this sprint (a) tags the VPC/IGW/route-table/subnets
`prodbox.io/managed-by=prodbox` so an escaped VPC is caught by the postflight tag sweep (these
VPC-scoped resources were previously untagged and invisible to it), and (b) guarantees the test
harness always provisions a fresh test VPC irrespective of any pre-existing one, via the existing
destroy-before-ensure residue purge.

### Deliverables

- `prodbox.io/managed-by=prodbox` tags on the `aws-eks` VPC, IGW, route table, and subnets in
  `pulumi/aws-eks/Main.yaml` (subnets keep their existing `kubernetes.io/cluster/<name>` +
  `kubernetes.io/role/elb` tags).
- The postflight tag sweep (`src/Prodbox/Lifecycle/TagSweep.hs`) surfaces an escaped VPC/IGW/RT/subnet
  as a per-run escapee.
- The always-fresh test VPC is documented as a guarantee of the destroy-before-ensure residue purge
  (`purgeCanonicalAwsEksResidueIfPresent` → `deleteVpcScopedResidue`), not a new mechanism.

### Validation

1. `cabal build --builddir=.build all --ghc-options=-Werror`
2. `./.build/prodbox test unit` (1145/1145; Pulumi VPC tag coverage + VPC-scoped escapee
   classification)
3. `./.build/prodbox dev lint haskell --write`
4. `./.build/prodbox dev docs generate`
5. `./.build/prodbox dev docs check`
6. `./.build/prodbox test integration cli` (39/39)
7. `./.build/prodbox test integration env` (39/39)
8. `git diff --check`
9. `./.build/prodbox dev check`

### Remaining Work

- Code-owned work closed. Remaining 🧪 Live-proof: exercise a real AWS `aws-eks` provision/destroy
  cycle and confirm the postflight tag sweep sees no escaped VPC-scoped residue after the existing
  destroy-before-ensure purge.

## Sprint 7.30: Daemon Object-Store API for Pulumi Backends [✅ Done]

**Status**: Done
**Live-proof**: pending for the live AWS/EKS daemon object-store parity run (non-blocking,
Standard O)
**Implementation**: `src/Prodbox/Pulumi/EncryptedBackend.hs`,
`src/Prodbox/Lifecycle/LiveResidue.hs`, `src/Prodbox/Infra/StackOutputs.hs`,
`src/Prodbox/Gateway/ObjectStore.hs`, `src/Prodbox/Gateway/Client.hs`,
`src/Prodbox/Gateway/Daemon.hs`, `src/Prodbox/Infra/AwsEksTestStack.hs`,
`src/Prodbox/Infra/AwsEksSubzoneStack.hs`, `src/Prodbox/Infra/AwsTestStack.hs`,
`src/Prodbox/Vault/Reconcile.hs`, `src/Prodbox/CLI/Rke2.hs`, `test/unit/Main.hs`,
`test/integration/CliSuite.hs`
**Independent Validation**: unit tests and fake-daemon CLI integration proving encrypted-backend
hydrate/store, residue queries, and stack-output reads use the daemon client without opening a local
MinIO port; live AWS parity remains a substrate row.
**Docs to update**: `documents/engineering/vault_doctrine.md`,
`documents/engineering/aws_integration_environment_doctrine.md`,
`documents/engineering/lifecycle_reconciliation_doctrine.md`, `DEVELOPMENT_PLAN/substrates.md`,
`DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md`

### Objective

Move the AWS/Pulumi encrypted-backend and residue surfaces behind the same daemon-mediated
post-bootstrap boundary as Vault lifecycle. The host Pulumi runner may still execute Pulumi
subprocesses, but persistent state hydration, store, residue, and output reads are served by the
daemon over the loopback-restricted NodePort and performed against MinIO in-cluster.

### Deliverables

- ✅ A daemon object-store API for typed Model-B object reads/writes needed by
  `Prodbox.Pulumi.EncryptedBackend`, including exact logical-object classification and redacted
  errors.
- ✅ `EncryptedBackend` hydrates scratch `file://` backends from daemon-served objects and stores the
  resulting checkpoint back through the daemon, with no `127.0.0.1:39000` MinIO endpoint in the
  supported path.
- ✅ `LiveResidue` and `StackOutputs` query encrypted checkpoints through the daemon client instead of
  batching a host MinIO port-forward.
- ✅ Legacy first-touch raw-checkpoint import remains explicit and bounded; after import, supported
  state cycles use only the daemon object-store API.
- ✅ The AWS-substrate docs and parity table stop describing host-local MinIO port-forwarding as the
  Pulumi backend transport.

### Validation

1. ✅ `cabal test --builddir=.build prodbox-unit --test-options=--hide-successes` — 1195/1195;
   covers daemon object-store request/response encoding, redacted checkpoint-bearing `Show`,
   gateway URL construction, Vault/MinIO policy grants, and supported per-run stack source
   regressions away from host MinIO port-forwarding.
2. ✅ `./.build/prodbox test unit` — 1195/1195.
3. ✅ `./.build/prodbox test integration cli` — 44/44; fake daemon object-store routes are exercised
   by the built frontend and the daemon-bootstrap trace proof still rejects legacy transport
   attempts.
4. ✅ `./.build/prodbox test integration env` — 44/44; no AWS/MinIO ambient env fallback is
   introduced.
5. Live-proof (Standard O): `prodbox test integration pulumi --substrate aws` and the AWS aggregate
   prove the daemon-backed object-store path against real EKS/MinIO.

### Remaining Work

- 🧪 Live-proof pending (non-blocking, Standard O): run the AWS-substrate Pulumi/aggregate parity
  proof against real EKS/MinIO. Remaining direct host MinIO helpers are explicit legacy/config/test
  seams tracked separately in the legacy ledger; the supported per-run Pulumi path no longer uses
  them.

## Related Documents

- [README.md](README.md)
- [00-overview.md](00-overview.md)
- [system-components.md](system-components.md)
- [substrates.md](substrates.md)
- [phase-5-canonical-test-suite.md](phase-5-canonical-test-suite.md)
- [phase-8-email-invite-auth.md](phase-8-email-invite-auth.md)
- [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md)
