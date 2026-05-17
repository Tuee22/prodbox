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

📋 **Planned (Sprint `7.5`)** — bring the AWS substrate to canonical-suite parity with the home
substrate. See the Sprint `7.5` block below.

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

2. **AWS substrate parity with the canonical suite (Sprint `7.5`, 📋 Planned)** — provision the
   AWS substrate so it stands up the same chart set, ingress, certificates, and DNS records
   that the home substrate provides today, and run the substrate-agnostic canonical-suite
   validations (`charts-vscode`, `charts-api`, `charts-websocket`, `public-dns`,
   `admin-routes`, public-edge readiness) against the AWS substrate. The suite content lives
   in [phase-5-canonical-test-suite.md](phase-5-canonical-test-suite.md); this sprint owns
   only the substrate's provisioning side so those validations have something to run against.

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

## Sprint 7.5: AWS Substrate Parity with the Canonical Suite 📋

**Status**: Planned
**Blocked by**: Existing AWS substrate foundations (Sprints `7.1`–`7.4`); Sprint `5.X` if the
canonical-suite content gains new prerequisites that need cross-substrate parity
**Implementation**: `src/Prodbox/Infra/AwsEksTestStack.hs`, `src/Prodbox/Infra/AwsTestStack.hs`,
`src/Prodbox/Prerequisite.hs`, `src/Prodbox/TestPlan.hs`, `src/Prodbox/TestRunner.hs`,
`src/Prodbox/TestValidation.hs`, `charts/`, `documents/engineering/aws_integration_environment_doctrine.md`
**Docs to update**: `DEVELOPMENT_PLAN/substrates.md`, `DEVELOPMENT_PLAN/README.md`,
`documents/engineering/aws_integration_environment_doctrine.md`,
`documents/engineering/unit_testing_policy.md`

### Objective

Bring the AWS substrate to behavioral parity with the home substrate for the canonical test
suite. After this sprint closes, every validation that runs on the home substrate today also
runs on the AWS substrate when the AWS substrate is the active substrate for a suite run, and
the substrate parity row in [substrates.md](substrates.md) for AWS becomes ✅ Full canonical
suite.

### Deliverables

- AWS substrate provisioning (per substrate, per active suite run) stands up:
  - A per-substrate Route 53 hosted zone or subdomain delegation (e.g. `aws.<configured_zone>`
    or a stack-specific subzone) so the substrate has its own public hostname distinct from
    the home substrate's `test.resolvefintech.com`.
  - cert-manager + the real Let's Encrypt ACME provider configured against that hosted zone.
  - An ingress comparable to the home substrate's MetalLB + Envoy Gateway pairing (EKS native
    NLB + Envoy Gateway, or equivalent — implementation choice belongs to this sprint).
  - The supported chart set (`gateway`, `keycloak`, `vscode`, `api`, `websocket`, plus their
    Patroni and Redis dependencies) deployed via `prodbox charts deploy` against the AWS
    substrate cluster.
  - The same prerequisite set (`infra_ready`, `public_edge_ready`, `k8s_ready`, chart-platform
    prereqs) satisfied for the AWS substrate.
- The canonical-suite content (`charts-vscode`, `charts-api`, `charts-websocket`,
  `public-dns`, `admin-routes`, public-edge readiness, plus phase-8's `keycloak-invite` when
  it lands) runs unchanged against the AWS substrate and produces the same pass/fail
  semantics as on the home substrate. The validations themselves do not change; only the
  substrate they target changes.
- AWS substrate teardown leaves no AWS residue: no orphaned hosted zone, no orphaned cert,
  no leaked ACME order/challenge, no stale `HTTPRoute` or `Certificate` resources, no leaked
  EBS volumes from chart PVCs.
- The substrate parity row in [substrates.md](substrates.md) for the AWS substrate is
  updated from 🔄 to ✅, with the link back to this sprint's closure date.
- The aggregate runner (`prodbox test integration all`, `prodbox test all`) optionally
  iterates the canonical suite over multiple substrates when configured to do so; the
  default substrate remains the home local substrate.

### Validation

1. `prodbox check-code`
2. `prodbox test unit`
3. `prodbox pulumi eks-resources`
4. `prodbox test integration aws-eks`
5. `prodbox test integration ha-rke2-aws`
6. The canonical-suite validations from
   [phase-5-canonical-test-suite.md](phase-5-canonical-test-suite.md) targeting the AWS
   substrate: `charts-vscode`, `charts-api`, `charts-websocket`, `public-dns` against the
   per-substrate hosted zone, `admin-routes`, and public-edge readiness.
7. AWS substrate teardown leaves zero AWS residue (verified by post-teardown account scan).
8. `prodbox test all` succeeds end-to-end against both substrates in sequence.

### Remaining Work

This sprint is `Planned`. Implementation has not started.

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
