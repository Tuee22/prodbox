# Phase 7: Interactive Onboarding, AWS IAM, and Quota Automation in Haskell

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [00-overview.md](00-overview.md), [system-components.md](system-components.md)

> **Purpose**: Define the supported Haskell onboarding wizard, standalone AWS IAM and quota command
> surface, and the elevated-credential validation harness for real IAM lifecycle proof.

## Phase Summary

This phase owns interactive config authoring, policy generation, IAM user management,
service-quota automation, and the test-only elevated credential harness. The Haskell worktree now
closes the intended credential boundary: public onboarding and public AWS administration prompt for
temporary elevated credentials, and stored `aws_admin.*` is consumed only by the native IAM
validation harness. The AWS-backed reruns now pass on the implemented repository surfaces. This
phase is closed on its owned credential and IAM boundaries.

## Current Baseline In Worktree

- The public onboarding and standalone AWS administration surfaces are Haskell-owned in
  `src/Prodbox/Aws.hs`, `src/Prodbox/CLI/Parser.hs`, and `src/Prodbox/Native.hs`. All Python
  command wrappers and IAM helpers have been removed.
- The settings path is fully Haskell-owned in `src/Prodbox/Settings.hs` for direct Dhall decode,
  display, and validation with no supported JSON materialization path.
- Haskell proof exists in `test/unit/Main.hs`, and the intended built-frontend fake-AWS proof
  lives in `test/integration/cli/Main.hs`. The real IAM lifecycle named proof runs through the
  native validation harness in `src/Prodbox/TestValidation.hs`.
- `src/Prodbox/TestPlan.hs` and `src/Prodbox/EffectInterpreter.hs` now gate `aws-iam` on an
  explicit native IAM harness readiness check before the validation body runs, while
  `src/Prodbox/SupportedRuntime.hs` no longer carries the retired non-test `aws_admin.*` repair
  path.
- The aggregate runner now reuses the canonical repo-backed Pulumi backend during prerequisite
  checks, so the IAM teardown-and-restore proof no longer depends on ambient host Pulumi login
  state.

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
  and does not depend on stored `aws_admin.*`.

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
  elevated credentials only; stored `aws_admin.*` is not read on the supported public path.
- On April 23, 2026, the latest reruns passed `./.build/prodbox test unit`,
  `./.build/prodbox test integration cli`, and the aggregate suites that continue to exercise the
  public onboarding surfaces.

### Remaining Work

- None.

## Sprint 7.2: Standalone IAM Lifecycle and Quota Automation in Haskell ✅

**Status**: Done
**Implementation**: `src/Prodbox/Aws.hs`, `src/Prodbox/CLI/Parser.hs`, `src/Prodbox/Native.hs`, `test/unit/Main.hs`, `test/integration/cli/Main.hs`
**Docs to update**: `documents/engineering/cli_command_surface.md`, `documents/engineering/aws_integration_environment_doctrine.md`

### Objective

Move the standalone AWS administration commands to Haskell while preserving the supported contract.

### Deliverables

- `prodbox aws setup|teardown|check-quotas|request-quotas` are implemented in Haskell.
- AWS CLI subprocess ownership and explicit credential injection remain canonical.
- IAM user lifecycle remains idempotent.
- Quota inspection and request automation preserve the supported quota set.
- Public `prodbox aws ...` commands obtain temporary elevated credentials interactively rather than
  from stored `aws_admin.*`.

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
  `aws_admin.*` config and use the interactively supplied temporary elevated credential instead.
- On April 23, 2026, the latest reruns passed `./.build/prodbox test integration cli`,
  `./.build/prodbox test integration aws-iam`, `./.build/prodbox test integration all`, and
  `./.build/prodbox test all`.

### Remaining Work

- None.

## Sprint 7.3: Elevated Credential Harness and Real IAM Lifecycle Proof on the Haskell Stack ✅

**Status**: Done
**Implementation**: `src/Prodbox/Settings.hs`, `src/Prodbox/Aws.hs`, `src/Prodbox/Effect.hs`, `src/Prodbox/EffectInterpreter.hs`, `src/Prodbox/Prerequisite.hs`, `src/Prodbox/SupportedRuntime.hs`, `src/Prodbox/TestPlan.hs`, `src/Prodbox/TestRunner.hs`, `src/Prodbox/TestValidation.hs`
**Docs to update**: `documents/engineering/aws_admin_credentials.md`, `documents/engineering/aws_account_setup_guide.md`, `documents/engineering/acme_provider_guide.md`, `documents/engineering/unit_testing_policy.md`

### Objective

Prove the real IAM lifecycle end to end using the Haskell rewrite and the isolated `aws_admin`
credential harness.

### Deliverables

- `aws_admin` remains isolated from the normal operational `aws.*` section.
- Real IAM setup and teardown validation closes on the Haskell stack.
- Stored `aws_admin.*` remains the single exception to the no-stored-admin-credentials rule and is
  read only by the native IAM validation harness.
- The aggregate runner preserves the supported credential rules without consuming `aws_admin.*`
  outside the test harness.
- The operator docs for account setup, ACME provider choice, and elevated credential handling are
  aligned with the Haskell implementation.

### Validation

1. `prodbox test unit`
2. `prodbox test integration cli`
3. `prodbox test integration env`
4. `prodbox test integration aws-iam`
5. `prodbox test all`

### Current Validation State

- The isolated `aws_admin` config contract and the Haskell IAM runtime surface are implemented in
  `src/Prodbox/Settings.hs` and `src/Prodbox/Aws.hs`.
- `src/Prodbox/TestPlan.hs`, `src/Prodbox/Prerequisite.hs`, and `src/Prodbox/EffectInterpreter.hs`
  now gate `prodbox test integration aws-iam` on native IAM harness readiness before the
  validation body runs.
- `src/Prodbox/TestValidation.hs` now re-establishes the operational IAM user after teardown proof
  so the aggregate validation harness can continue on supported `aws.*` credentials.
- `src/Prodbox/SupportedRuntime.hs` now contains only the retained supported-runtime helpers; the
  retired non-test `aws_admin.*` recovery path has been removed.
- `src/Prodbox/EffectInterpreter.hs` now checks `pulumi whoami` against the canonical
  repo-backed MinIO backend during prerequisites, so the aggregate IAM proof no longer depends on
  stale ambient Pulumi host-login state.
- On April 23, 2026, the latest reruns passed `./.build/prodbox test unit`,
  `./.build/prodbox test integration cli`, `./.build/prodbox test integration env`,
  `./.build/prodbox test integration aws-iam`, `./.build/prodbox test integration all`, and
  `./.build/prodbox test all`.
- The aggregate IAM proof now executes successfully before the downstream AWS-backed suites rather
  than failing at prerequisite validation.

### Remaining Work

None. The IAM harness and aggregate reruns are no longer blocked by repo-root operational AWS
credentials, and no remaining Phase `7` implementation work survives.

## Documentation Requirements

**Engineering docs to create/update:**

- `documents/engineering/aws_account_setup_guide.md` - Haskell onboarding and temporary elevated
  credential workflow.
- `documents/engineering/aws_admin_credentials.md` - Haskell `aws_admin` harness and cleanup rules.
- `documents/engineering/acme_provider_guide.md` - ACME provider choice in the rewritten setup
  flow.
- `documents/engineering/cli_command_surface.md` - `config setup` and `aws *` command matrix.
- `documents/engineering/aws_integration_environment_doctrine.md` - retained AWS admin rules after
  the rewrite.
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
