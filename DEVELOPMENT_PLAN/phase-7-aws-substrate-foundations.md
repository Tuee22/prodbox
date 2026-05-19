# Phase 7: AWS Substrate Foundations

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [00-overview.md](00-overview.md),
[system-components.md](system-components.md),
[substrates.md](substrates.md),
[phase-8-email-invite-auth.md](phase-8-email-invite-auth.md),
[legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md),
[../HASKELL_CLI_TOOL.md](../HASKELL_CLI_TOOL.md)

> **Purpose**: Own the AWS substrate's foundations — the interactive onboarding wizard, the
> standalone AWS IAM and quota command surface, the elevated-credential validation harness for
> real IAM lifecycle proof, and (Sprint `7.5`) the AWS-substrate-parity sprint that brings the
> AWS substrate to canonical-suite parity with the home substrate.

## Phase Status

✅ **Done on owned surfaces** for the historical foundations work — Sprints `7.1`–`7.4` remain
closed on interactive onboarding, AWS IAM management, quota automation, and the
elevated-credential validation harness. Per
[development_plan_standards.md](development_plan_standards.md) standards rule E, Phase 7 stays
`Done` on its owned legacy scope while Phases `0`–`4` are reopened by Sprint 0.2 to adopt
[../HASKELL_CLI_TOOL.md](../HASKELL_CLI_TOOL.md). The interactive onboarding flow and standalone
`prodbox aws ...` surface inherit the Plan / Apply + `--dry-run` discipline (Sprint 1.7), the
`CommandSpec` source-of-truth split (Sprint 1.6), and the capability classes for AWS subsystems
(Sprint 1.12) without scheduling a new Sprint 7.X for those concerns.

🔄 **Active (Sprint `7.5`)** — bring the AWS substrate to canonical-suite parity with the home
substrate. The May 2026 scoping review split Sprint `7.5` into three sub-sprints whose
deliverables are sized for sequential, separately validatable sessions:

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
- **Sprint `7.5.b`** (🔄 Active, split into `7.5.b.i` and `7.5.b.ii` per the May 17, 2026
  scoping check-in):
  - **`7.5.b.i`** (✅ Done, May 17, 2026) — code-side substrate foundations: EKS kubeconfig
    extraction (`materializeAwsEksKubeconfig` in `src/Prodbox/Infra/AwsEksTestStack.hs`),
    substrate-aware helpers (`substrateKubeconfigPath`, `substrateHostedZoneId`,
    `substratePublicFqdn` in `src/Prodbox/PublicEdge.hs`), and the `aws_substrate` Dhall
    block (`hosted_zone_id`, `subzone_name`) wired through
    `prodbox-config-types.dhall`, `prodbox-config.dhall`, and
    `src/Prodbox/Settings.hs::AwsSubstrateSection`. Code-only; validated with
    `prodbox check-code` and `prodbox test unit` (296/296 pass).
  - **`7.5.b.ii`** (📋 Planned) — AWS Load Balancer Controller IAM policy + IRSA setup in
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
- **Sprint `7.5.c`** (🔄 Active) — code follow-up landed May 18, 2026
  (`substratePublicFqdn` / `substrateHostedZoneId` fail-fast,
  `resolveAwsEksSubzoneStackConfig` pre-provision gate loosened, `isAwsSubstrateConfigured`
  removed, `prodbox-config.dhall` re-frozen with the operator-supplied
  `aws_substrate.subzone_name`, ledger row moved from Pending to Completed). Live
  AWS-substrate canonical-suite validation (`charts-vscode`, `charts-api`,
  `charts-websocket`, `public-dns`, `admin-routes`, public-edge readiness) plus
  zero-residue teardown scan and Substrate parity table flip in
  [substrates.md](substrates.md) and [README.md](README.md) remain the operator-driven
  closing steps.

## Phase Summary

This phase owns AWS substrate foundations:

1. **AWS substrate foundations (historical, ✅ Done)** — interactive config authoring, policy
   generation, IAM user management, service-quota automation, and the test-only elevated
   credential harness. The implemented credential boundary is Haskell-owned: public
   onboarding and public AWS administration prompt for temporary elevated credentials, and
   stored `aws_admin_for_test_simulation.*` exists only for test-suite simulation of that
   ephemeral prompt input, with the native IAM validation harness as the only supported
   runtime consumer. The shared suite-level IAM harness keeps the aggregate Pulumi-backend
   proof behind the visible local runbook and closes the supported aggregate validation path
   on Haskell-owned AWS-user and config cleanup. Sprint `7.4` is closed on the single-host
   onboarding and placeholder-domain removal doctrine for `test.resolvefintech.com`.

2. **AWS substrate parity with the canonical suite (Sprint `7.5`, 🔄 Active, split into
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
  `Dhall -> Haskell types` contract through the `dhall-to-json` bridge, display, and validation
  with no supported JSON materialization path.
- Haskell proof exists in `test/unit/Main.hs`, and the intended built-frontend fake-AWS proof
  lives in `test/integration/CliSuite.hs`. The real IAM lifecycle named proof runs through the
  native validation harness in `src/Prodbox/TestValidation.hs`.
- `src/Prodbox/TestPlan.hs` and `src/Prodbox/EffectInterpreter.hs` now gate `aws-iam` on an
  explicit native IAM harness readiness check before the validation body runs. The retired
  non-test `aws_admin_for_test_simulation.*` recovery path is removed.
- `src/Prodbox/TestPlan.hs` already routes `prodbox test integration aws-iam`,
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
  duration of `prodbox test integration aws-iam`, `prodbox test integration all`, and
  `prodbox test all`, then clears those credentials again even when later prerequisites fail.
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
- The wizard writes and validates `prodbox-config.dhall` without Python helpers.
- The supported public bootstrap path prompts the operator for one temporary elevated credential set
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
  elevated credentials only; stored `aws_admin_for_test_simulation.*` is not read on the
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
- Public `prodbox aws ...` commands obtain temporary elevated credentials interactively rather than
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
  `aws_admin_for_test_simulation.*` config and use the interactively supplied temporary elevated
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
- `prodbox test integration aws-iam`, `prodbox test integration all`, and `prodbox test all`
  share one joint idempotent IAM validation harness.
- That shared harness begins by deleting any pre-existing dedicated `prodbox` IAM user and all of
  that user's access keys.
- When pre-existing operational `aws.*` credentials exist in `prodbox-config.dhall`, the harness
  uses those credentials only to discover and delete the IAM user associated with them before it
  provisions fresh operational credentials.
- Real IAM setup and teardown validation closes on the Haskell stack without leaving a dedicated
  `prodbox` IAM user or operational `aws.*` credentials behind.
- Stored `aws_admin_for_test_simulation.*` remains the single exception to the
  no-stored-admin-credentials rule and exists only for test-suite simulation of the ephemeral
  elevated credential prompt.
- The native IAM validation harness remains the only supported runtime consumer of
  `aws_admin_for_test_simulation.*`.
- The shared harness simulates the interactive public CLI workflow by materializing operational
  `aws.*` only from `aws_admin_for_test_simulation.*` for the duration of the validation run.
- The shared harness clears operational `aws.*` from `prodbox-config.dhall` before returning.
- The operator docs for account setup, ACME provider choice, and elevated credential handling are
  aligned with the Haskell implementation.

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
- The retired non-test `aws_admin_for_test_simulation.*` recovery path has been removed.
- `src/Prodbox/TestPlan.hs`, `src/Prodbox/TestRunner.hs`, and `src/Prodbox/Prerequisite.hs` now
  split the aggregate and cluster-backed suite prerequisite contract into an initial fail-fast
  gate plus a deferred backend proof, so `pulumi_logged_in` no longer runs before the visible
  `rke2 reconcile` phase has created or repaired the supported local MinIO backend.
- `src/Prodbox/EffectInterpreter.hs` now checks bounded `pulumi login ... --non-interactive`
  against the canonical repo-backed MinIO backend during deferred prerequisites, and the shared
  `src/Prodbox/Infra/MinioBackend.hs` helper recreates a deleted MinIO export host path plus
  restarts `deployment/minio` before retrying that proof, so the aggregate IAM run no longer
  depends on stale ambient Pulumi host-login state or a detached retained-storage mount.
- The aggregate IAM proof is sequenced before downstream AWS-backed suites through the named
  prerequisite DAG rather than through ambient host Pulumi login state.
- The named and aggregate IAM closure gates are implemented on the same native suite path:
  `prodbox test integration aws-iam`, `prodbox test integration all`, and `prodbox test all`.
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

## Sprint 7.5: AWS Substrate Parity with the Canonical Suite 🔄

**Status**: Active (split into `7.5.a`, `7.5.b`, `7.5.c`)
**Blocked by**: Existing AWS substrate foundations (Sprints `7.1`–`7.4`); Sprint `5.X` if the
canonical-suite content gains new prerequisites that need cross-substrate parity

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
  - cert-manager + the real Let's Encrypt ACME provider configured against that hosted zone.
    (`7.5.b`)
  - An ingress comparable to the home substrate's MetalLB + Envoy Gateway pairing (EKS native
    NLB + Envoy Gateway, or equivalent — implementation choice belongs to this sprint).
    (`7.5.b`)
  - The supported chart set (`gateway`, `keycloak`, `vscode`, `api`, `websocket`, plus their
    Patroni and Redis dependencies) deployed via `prodbox charts deploy` against the AWS
    substrate cluster. (`7.5.b`)
  - The same prerequisite set (`infra_ready`, `public_edge_ready`, `k8s_ready`, chart-platform
    prereqs) satisfied for the AWS substrate. (`7.5.b`)
- The canonical-suite content (`charts-vscode`, `charts-api`, `charts-websocket`,
  `public-dns`, `admin-routes`, public-edge readiness, plus phase-8's `keycloak-invite` when
  it lands) runs unchanged against the AWS substrate and produces the same pass/fail
  semantics as on the home substrate. The validations themselves do not change; only the
  substrate they target changes. (`7.5.c`)
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
- `prodbox-config-types.dhall` (and the matching `prodbox-config.dhall`) gain an optional
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

## Sprint 7.5.b: AWS-Native Ingress, cert-manager DNS01, and AWS-Substrate Chart Deploy 🔄

**Status**: Active (split into `7.5.b.i` ✅ and `7.5.b.ii` 📋 per the May 17, 2026 scoping
check-in)
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
`src/Prodbox/Settings.hs`, `prodbox-config-types.dhall`, `prodbox-config.dhall`,
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
  block is required for any `--substrate aws` canonical-suite run; `prodbox-config.dhall` has
  its `sha256:` import hash re-frozen against the updated schema.
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
5. `dhall-to-json --file prodbox-config.dhall --compact --preserve-null` emits the new
   `aws_substrate` JSON block.

### Remaining Work

None. The AWS Load Balancer Controller IAM + IRSA, Route 53 subzone Pulumi program,
substrate-aware `ClusterIssuer` rendering, substrate-aware `ChartPlatform.hs` branching, and
AWS LB Controller + Envoy Gateway install paths are owned by Sprint `7.5.b.ii`.

## Sprint 7.5.b.ii: AWS Load Balancer Controller, Route 53 Subzone, and Chart-Deploy Substrate Branching 🔄

**Status**: Active (`7.5.b.ii.a` ✅ done May 17, 2026; `7.5.b.ii.b`/`7.5.b.ii.c`/`7.5.b.ii.d`
📋 Planned). The May 17, 2026 scoping pass further split this sub-sprint into four
session-sized sub-sub-sprints because the combined surface (Pulumi + ClusterIssuer +
ChartPlatform substrate threading + AWS LB Controller + Envoy Gateway install) is too large
for one session.

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
- **`7.5.b.ii.c`** (🔄 Active, split into `7.5.b.ii.c.I` ✅ done May 17, 2026, and
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
    CLI surface: `prodbox pulumi aws-subzone-resources` and
    `prodbox pulumi aws-subzone-destroy` (with `--yes`/`--dry-run`/`--plan-file`)
    registered through `PulumiAwsSubzoneResources` / `PulumiAwsSubzoneDestroy`
    variants on `PulumiCommand`. Validated with `prodbox check-code` (exit 0),
    `prodbox docs generate` regeneration, and `prodbox test unit` (300/300 pass; up
    from 296 because the two new pulumi subcommands each add a happy-case + an
    unhappy-case parser test).
- **`7.5.b.ii.d`** (🔄 Active, split into `7.5.b.ii.d.I` ✅ done May 17, 2026 and
  `7.5.b.ii.d.II` 📋):
  - **`7.5.b.ii.d.I`** (✅ Done, May 17, 2026) — `prodbox charts deploy` and
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
  - **`7.5.b.ii.d.II`** (🔄 Active; the May 17, 2026 scoping pass split this into
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
      `prodbox charts deploy --substrate aws`; the wiring lands in `β` once the
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
      `kubectl wait --for=condition=Ready clusterissuer/letsencrypt-http01`s.
      `Prodbox.Lib.AwsSubstratePlatform::ensureAwsSubstratePlatformRuntime`
      sequences `α`+`β`+`γ`+ACME after loading the EKS snapshot, failing fast
      when `prodbox pulumi eks-resources` has not yet been run. The
      orchestrator is wired into `prodbox charts deploy <chart> --substrate
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
  Route 53 provider scoped to the subzone) so real Let's Encrypt certificates issue against
  the AWS-substrate FQDN.
- Envoy Gateway plus the supported chart set (`gateway`, `keycloak`, `vscode`, `api`,
  `websocket`, plus their dependencies) deployable through `prodbox charts deploy <chart>
  --substrate aws` against the AWS-substrate cluster.
- All AWS-substrate-aware code paths added in 7.5.a/7.5.b.i have their behavior implemented
  (no more "AWS substrate path not yet implemented" remedies on chart-deploy or ingress
  paths).

### Validation

1. `prodbox check-code`
2. `prodbox test unit`
3. `prodbox pulumi eks-resources` (existing)
4. `prodbox test integration aws-eks` (existing) — confirms substrate provisioning still
   stable.
5. `prodbox charts deploy gateway --substrate aws` (and the rest of the chart set) succeed
   against the AWS substrate.
6. cert-manager issues real Let's Encrypt certificates against the per-substrate hosted zone.

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

## Sprint 7.5.c: Live AWS-Substrate Canonical-Suite Validation 📋

**Status**: Planned
**Blocked by**: Sprint `7.5.b`
**Implementation**: `src/Prodbox/TestValidation.hs`, `src/Prodbox/Infra/AwsEksTestStack.hs`,
`src/Prodbox/Infra/AwsTestStack.hs`
**Docs to update**: `DEVELOPMENT_PLAN/substrates.md`, `DEVELOPMENT_PLAN/README.md`,
`DEVELOPMENT_PLAN/phase-7-aws-substrate-foundations.md`,
`documents/engineering/unit_testing_policy.md`

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
3. `prodbox pulumi eks-resources`
4. `prodbox test integration aws-eks`
5. `prodbox test integration ha-rke2-aws`
6. `prodbox test integration charts-vscode --substrate aws`
7. `prodbox test integration charts-api --substrate aws`
8. `prodbox test integration charts-websocket --substrate aws`
9. `prodbox test integration public-dns --substrate aws`
10. `prodbox test integration admin-routes --substrate aws`
11. AWS post-teardown residue scan returns zero.
12. `prodbox test all` (home substrate, default) still green.

### Operator Workflow

Per
[development_plan_standards.md → M. Substrate coverage and independence (no fallback)](development_plan_standards.md#substrate-coverage-and-independence-no-fallback),
an AWS-substrate canonical-suite run is locked to AWS-substrate config; nothing falls back
to the home substrate. The Sprint `7.5.c` operator workflow is therefore:

1. Operator chooses the AWS-substrate public FQDN (the `subzone_name`, e.g.
   `aws.test.resolvefintech.com`) and sets it in
   `prodbox-config.dhall::aws_substrate.subzone_name`.
2. Operator runs `prodbox pulumi eks-resources` to provision the EKS cluster, IRSA, and
   subnet tags.
3. Operator runs `prodbox pulumi aws-subzone-resources` to provision the per-substrate
   Route 53 subzone and NS delegation in the parent zone. The stack snapshot at
   `.prodbox-state/aws-eks-subzone/` reports the new subzone's hosted zone ID.
4. Operator copies the reported subzone ID into
   `prodbox-config.dhall::aws_substrate.hosted_zone_id` so downstream validations (the
   AWS-substrate ACME `ClusterIssuer`, `public-dns`, `admin-routes`) write into the
   AWS-substrate's own Route 53 zone.
5. Operator runs the five AWS-substrate canonical-suite validations
   (`charts-vscode`, `charts-api`, `charts-websocket`, `public-dns`, `admin-routes`)
   with `--substrate aws`.
6. After validation, operator tears down with `prodbox pulumi aws-subzone-destroy --yes`
   and `prodbox pulumi eks-destroy --yes` (plus `prodbox pulumi test-destroy --yes` if
   the HA-RKE2 EC2 stack was provisioned).

### Code Follow-Up

Sprint `7.5.c`'s validation arms refinement budget owns the code reconciliation between
the substrate-independence doctrine (Sprint `7.5.b.iii`) and the shipped helper /
lifecycle gate behavior:

- `src/Prodbox/PublicEdge.hs::substratePublicFqdn` and `substrateHostedZoneId` replace
  their home-substrate fallback branches with a fail-fast `error` (or `Either`-returning
  variant called from validated entrypoints) so AWS-substrate runs cannot silently use
  home values when `aws_substrate.hosted_zone_id` or `aws_substrate.subzone_name` is
  empty.
- `src/Prodbox/Infra/AwsEksSubzoneStack.hs::resolveAwsEksSubzoneStackConfig` loosens its
  pre-provision gate to require only `subzone_name` (the value Pulumi actually consumes
  at provision time); `hosted_zone_id` becomes a post-provision requirement enforced at
  the validation arm that consumes it. This removes the chicken-and-egg around the
  initial subzone provisioning while preserving the doctrine that downstream validations
  fail fast when the value is missing.
- The entry in [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md) for the
  helper fallback semantics closes when this code follow-up lands.

### Current Validation State (Code Follow-Up Landed)

- `src/Prodbox/PublicEdge.hs::substratePublicFqdn` and `substrateHostedZoneId` now raise
  fail-fast `error` calls naming
  [development_plan_standards.md → M. Substrate coverage and independence (no fallback)](development_plan_standards.md#substrate-coverage-and-independence-no-fallback)
  when the AWS-substrate `subzone_name` or `hosted_zone_id` field is empty. The
  home-substrate branches still resolve to the existing `route53.zone_id` and
  `domain.demo_fqdn` paths unchanged.
- `src/Prodbox/Infra/AwsEksSubzoneStack.hs::resolveAwsEksSubzoneStackConfig` now requires
  only `subzone_name` at pre-provision time; downstream consumers enforce
  `hosted_zone_id` as a post-provision requirement.
- The now-unused `isAwsSubstrateConfigured` helper is removed from
  `src/Prodbox/Settings.hs`; the matching ledger row in
  [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md) is moved from
  Pending Removal to Completed (Sprint `7.5.c` code follow-up on May 18, 2026).
- `prodbox-config.dhall` is re-frozen against the current
  `prodbox-config-types.dhall` hash so `aws_substrate` is materialized in the
  `dhall-to-json` output, and the operator's `aws_substrate.subzone_name` is set to
  `aws.test.resolvefintech.com` per the Operator Workflow step 1.
- Validated with `prodbox check-code` (exit 0) and `prodbox test unit` (300/300) on May
  18, 2026.

### Live Operator Workflow Progress (May 18, 2026 session)

Live workflow attempts surfaced three concrete bugs in the substrate-aware code that
landed in Sprints `7.5.b.ii.d.II.α/β/γ/δ`. Two were fixed this session; the third is
substantial and remains open. Per the substrate-equivalence doctrine recorded in
[../CLAUDE.md](../CLAUDE.md) and [../AGENTS.md](../AGENTS.md), the AWS substrate
stands up the same chart set + supporting platform (Harbor, MinIO, Percona operator,
Envoy Gateway, cert-manager, real Let's Encrypt) as the home substrate; differences
are limited to the load balancer (MetalLB ↔ AWS LB Controller) and Route 53 hosting
(parent zone ↔ subzone).

**Fixed this session:**

- `Prodbox.CLI.Charts.withSubstrateEnvironment` and
  `Prodbox.TestValidation.withSubstrateKubeconfigEnv` now bracket-set
  `KUBECONFIG` + `AWS_ACCESS_KEY_ID` + `AWS_SECRET_ACCESS_KEY` +
  `AWS_DEFAULT_REGION` + `AWS_REGION` (and optional `AWS_SESSION_TOKEN`) from
  `settings.aws.*`, so EKS's `aws eks get-token` exec provider can fetch a token
  for kubectl/helm subprocesses on the AWS substrate. Without this, every kubectl
  call against EKS failed with `401 the server has asked for the client to provide
  credentials`.
- `Prodbox.Lib.AwsSubstratePlatform.extractRegionFromArn` now preserves empty ARN
  segments (`splitKeepingEmpty` replaces the earlier `wordsBy` which dropped empty
  segments and returned the IAM account number as the "region"). Helm string
  values switched to `--set-string` so the chart's string-typed `region` field
  stops being parsed as `int64`. Caller now passes the configured `aws.region`
  as the fallback.
- `Prodbox.Lib.AwsSubstratePlatform.ensureAwsSubstrateAcmeRuntime` wraps the
  `[Value]` ACME manifest list as a `v1/List` object before `kubectl apply -f`
  (matches the home-substrate `Prodbox.CLI.Rke2.withTemporaryJsonManifest`
  pattern). Without this, `kubectl apply -f` rejected the bare JSON array with
  `invalid object to validate`.

With these three fixes, `prodbox charts deploy gateway --substrate aws` reaches and
completes the substrate-platform install on EKS:

- `aws-load-balancer-controller` (`kube-system`) — deployment Ready.
- `envoy-gateway` (`envoy-gateway-system`) — deployment Ready.
- `cert-manager` + `cert-manager-webhook` + `cert-manager-cainjector`
  (`cert-manager`) — deployments Ready.
- `route53-credentials` + `acme-eab-credentials` secrets created.
- `letsencrypt-http01` `ClusterIssuer` created and Ready.

**Remaining work (substantial Sprint `7.5.c` follow-up):**

`Prodbox.Lib.AwsSubstratePlatform.ensureAwsSubstratePlatformRuntime` currently
installs only the load-balancer / ingress / cert-manager / ACME pieces. Per the
substrate-equivalence doctrine, the AWS substrate also needs:

- **Harbor** — the chart-platform image refs (`charts/*/values.yaml` and
  `Prodbox.Lib.ChartPlatform.valuesForKeycloak` / etc.) use one set across both
  substrates: `127.0.0.1:30080/prodbox/...`. On home, Harbor runs as a NodePort
  service exposed at `127.0.0.1:30080`. On AWS, the platform install needs to
  bring Harbor up (with its MinIO storage backend) so `127.0.0.1:30080` resolves
  on EKS nodes the same way it does on home cluster nodes.
- **MinIO** — Harbor's S3 storage backend, plus the gateway daemon's Pulumi
  backend. Currently home-only.
- **Percona PostgreSQL operator** — the `keycloak-postgres` chart depends on the
  cluster-wide Percona operator (`charts/keycloak-postgres` references
  `pgv2.percona.com` CRDs). Currently home-only.
- **Image mirror loop** — the home substrate's
  `Prodbox.CLI.Rke2.mirrorRequiredImagesIntoHarbor` step pushes upstream images
  into the Harbor mirror so chart pods can pull them via `127.0.0.1:30080`. The
  AWS substrate needs an equivalent step running against EKS's Harbor.

Implementation owner: extend `Prodbox.Lib.AwsSubstratePlatform` with helpers
mirroring `Prodbox.CLI.Rke2.ensureClusterPlatformRuntime`'s Harbor/MinIO/Percona
sub-steps + the image-mirror loop, and wire them into
`ensureAwsSubstratePlatformRuntime`. Estimate: 4–8 hours of careful chart-platform
work.

**Current AWS-substrate state at session end:**

- EKS cluster `aws-eks-test-cluster` (us-west-2, 2-node group) — provisioned.
- Route 53 subzone `aws.test.resolvefintech.com` (`Z09855634DAFL96UPV1E`) —
  provisioned, NS delegation in parent zone.
- AWS LB Controller + Envoy Gateway + cert-manager + ACME ClusterIssuer — Ready on
  EKS.
- `gateway` helm release deployed to EKS `gateway` namespace; pods in
  `ImagePullBackOff` waiting on the Harbor+MinIO substrate-platform follow-up
  above.
- `aws.*` credentials populated in `prodbox-config.dhall` (sourced from
  `aws_admin_for_test_simulation.*`). Teardown when ready:
  `prodbox pulumi aws-subzone-destroy --yes` +
  `prodbox pulumi eks-destroy --yes`; afterwards clear `aws.*` in the dhall.

### Remaining Work

The two doc-friendly fixes above land cleanly. Sprint `7.5.c` does not close until
the Harbor+MinIO+Percona substrate-platform follow-up lands and the five
`--substrate aws` canonical-suite validations run green against a substrate that
fully matches the home cluster's chart-set state.

## Documentation Requirements

**Engineering docs to create/update:**

- `documents/engineering/aws_account_setup_guide.md` - Haskell onboarding and temporary elevated
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

**Product docs to create/update:**

- None.

**Cross-references to add:**

- Keep the onboarding and AWS administration docs linked from
  [documents/engineering/README.md](../documents/engineering/README.md).

## Related Documents

- [README.md](README.md)
- [00-overview.md](00-overview.md)
- [system-components.md](system-components.md)
- [substrates.md](substrates.md)
- [phase-5-canonical-test-suite.md](phase-5-canonical-test-suite.md)
- [phase-8-email-invite-auth.md](phase-8-email-invite-auth.md)
- [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md)
