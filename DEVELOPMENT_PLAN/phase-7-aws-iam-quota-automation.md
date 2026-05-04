# Phase 7: Interactive Onboarding, AWS IAM, and Quota Automation in Haskell

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [00-overview.md](00-overview.md),
[system-components.md](system-components.md),
[legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md)

> **Purpose**: Define the supported Haskell onboarding wizard, standalone AWS IAM and quota command
> surface, and the elevated-credential validation harness for real IAM lifecycle proof.

## Phase Summary

This phase owns interactive config authoring, policy generation, IAM user management,
service-quota automation, and the test-only elevated credential harness. The implemented
credential boundary is now Haskell-owned: public onboarding and public AWS administration prompt
for temporary elevated credentials, and stored `aws_admin_for_test_simulation.*` exists only for
test-suite simulation of that ephemeral prompt input, with the native IAM validation harness as
the only supported runtime consumer. The shared suite-level IAM harness keeps the aggregate
Pulumi-backend proof behind the visible local runbook and closes the supported local-cluster
aggregate validation path on Haskell-owned AWS-user and config cleanup. Sprint `7.4` is now
closed on the single-host onboarding and placeholder-domain removal doctrine for
`test.resolvefintech.com`.

## Current Baseline In Worktree

- The public onboarding and standalone AWS administration surfaces are Haskell-owned in
  `src/Prodbox/Aws.hs`, `src/Prodbox/CLI/Parser.hs`, and `src/Prodbox/Native.hs`. All Python
  command wrappers and IAM helpers have been removed.
- The settings path is fully Haskell-owned in `src/Prodbox/Settings.hs` for the direct
  `Dhall -> Haskell types` contract through the `dhall-to-json` bridge, display, and validation
  with no supported JSON materialization path.
- Haskell proof exists in `test/unit/Main.hs`, and the intended built-frontend fake-AWS proof
  lives in `test/integration/cli/Main.hs`. The real IAM lifecycle named proof runs through the
  native validation harness in `src/Prodbox/TestValidation.hs`.
- `src/Prodbox/TestPlan.hs` and `src/Prodbox/EffectInterpreter.hs` now gate `aws-iam` on an
  explicit native IAM harness readiness check before the validation body runs, while
  `src/Prodbox/SupportedRuntime.hs` no longer carries the retired non-test
  `aws_admin_for_test_simulation.*` repair path.
- `src/Prodbox/TestPlan.hs` already routes `prodbox test integration aws-iam`,
  `prodbox test integration all`, and `prodbox test all` through the same managed IAM harness
  ownership in `src/Prodbox/TestRunner.hs`, while `src/Prodbox/TestValidation.hs` now treats
  `ValidationAwsIam` as an inspection step rather than as the setup/teardown owner.
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
**Implementation**: `src/Prodbox/Aws.hs`, `src/Prodbox/CLI/Parser.hs`, `src/Prodbox/Native.hs`, `test/unit/Main.hs`, `test/integration/cli/Main.hs`
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
- `test/integration/cli/Main.hs` is the intended built-frontend fake-AWS proof surface for
  `config setup` and `aws policy --tier full`.
- `src/Prodbox/Aws.hs` now keeps the public `config setup` flow on prompt-driven temporary
  elevated credentials only; stored `aws_admin_for_test_simulation.*` is not read on the
  supported public path.
### Remaining Work

None.

## Sprint 7.2: Standalone IAM Lifecycle and Quota Automation in Haskell ✅

**Status**: Done
**Implementation**: `src/Prodbox/Aws.hs`, `src/Prodbox/CLI/Parser.hs`, `src/Prodbox/Native.hs`, `test/unit/Main.hs`, `test/integration/cli/Main.hs`
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
- `test/integration/cli/Main.hs` is the intended built-frontend fake-AWS proof surface for
  setup/teardown and quota flows.
- `test/integration/cli/Main.hs` now proves the public `prodbox aws ...` commands ignore populated
  `aws_admin_for_test_simulation.*` config and use the interactively supplied temporary elevated
  credential instead.
### Remaining Work

None.

## Sprint 7.3: Elevated Credential Harness and Real IAM Lifecycle Proof on the Haskell Stack ✅

**Status**: Done
**Implementation**: `src/Prodbox/Settings.hs`, `src/Prodbox/Aws.hs`, `src/Prodbox/Effect.hs`, `src/Prodbox/EffectInterpreter.hs`, `src/Prodbox/Prerequisite.hs`, `src/Prodbox/SupportedRuntime.hs`, `src/Prodbox/TestPlan.hs`, `src/Prodbox/TestRunner.hs`, `src/Prodbox/TestValidation.hs`
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
  resolve it, clearing operational `aws.*`, and then provisioning fresh operational credentials
  from `aws_admin_for_test_simulation.*`.
- `src/Prodbox/TestValidation.hs` now limits `ValidationAwsIam` to inspecting the managed
  operational IAM identity, while `src/Prodbox/TestRunner.hs` owns harness teardown so aggregate
  AWS-backed validations can continue to use the temporary operational credentials until suite
  completion.
- `src/Prodbox/SupportedRuntime.hs` now contains only the retained supported-runtime helpers; the
  retired non-test `aws_admin_for_test_simulation.*` recovery path has been removed.
- `src/Prodbox/TestPlan.hs`, `src/Prodbox/TestRunner.hs`, and `src/Prodbox/Prerequisite.hs` now
  split the aggregate and cluster-backed suite prerequisite contract into an initial fail-fast
  gate plus a deferred backend proof, so `pulumi_logged_in` no longer runs before the visible
  `rke2 install` phase has created or repaired the supported local MinIO backend.
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
**Implementation**: `src/Prodbox/Aws.hs`, `src/Prodbox/Settings.hs`, `src/Prodbox/CLI/Parser.hs`, `src/Prodbox/Native.hs`, `test/unit/Main.hs`, `test/integration/cli/Main.hs`, `test/integration/env/Main.hs`, `prodbox-config-types.dhall`
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
- [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md)
