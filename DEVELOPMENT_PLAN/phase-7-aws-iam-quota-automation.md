# Phase 7: Interactive Onboarding, AWS IAM, and Quota Automation in Haskell

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [00-overview.md](00-overview.md), [system-components.md](system-components.md)

> **Purpose**: Define the supported Haskell onboarding wizard, standalone AWS IAM and quota command
> surface, and the elevated-credential validation harness for real IAM lifecycle proof.

## Phase Summary

This phase ported the highest-friction operator flows to Haskell: interactive config authoring,
policy generation, IAM user management, service-quota automation, and the test-only elevated
credential harness. All onboarding and AWS administration surfaces are now Haskell-owned, Sprint
`6.2` closed after the Python dependency was fully removed, and the reopened real-IAM proof now
also closes through the native validation harness.

## Current Baseline In Worktree

- The public onboarding and standalone AWS administration surfaces are Haskell-owned in
  `src/Prodbox/Aws.hs`, `src/Prodbox/CLI/Parser.hs`, and `src/Prodbox/Native.hs`. All Python
  command wrappers and IAM helpers have been removed.
- The settings path is fully Haskell-owned in `src/Prodbox/Settings.hs` for direct Dhall decode,
  display, and validation with no supported JSON materialization path.
- Haskell proof exists in `test/unit/Main.hs`, and the intended built-frontend fake-AWS proof
  lives in `test/integration/cli/Main.hs`; that suite now passes on the April 18, 2026 worktree.
  The real IAM lifecycle named proof now runs through the native validation harness in
  `src/Prodbox/TestValidation.hs`.

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
  `config setup` and `aws policy --tier full`, and that automated proof now passes.

### Remaining Work

None.

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
  setup/teardown and quota flows, and that automated proof now passes.

### Remaining Work

None.

## Sprint 7.3: Elevated Credential Harness and Real IAM Lifecycle Proof on the Haskell Stack ✅

**Status**: Done
**Implementation**: `src/Prodbox/Settings.hs`, `src/Prodbox/Aws.hs`, `src/Prodbox/TestPlan.hs`, `src/Prodbox/TestRunner.hs`
**Docs to update**: `documents/engineering/aws_admin_credentials.md`, `documents/engineering/aws_account_setup_guide.md`, `documents/engineering/acme_provider_guide.md`, `documents/engineering/unit_testing_policy.md`

### Objective

Re-prove the real IAM lifecycle end to end using the Haskell rewrite and the isolated `aws_admin`
credential harness.

### Deliverables

- `aws_admin` remains isolated from the normal operational `aws.*` section.
- Real IAM setup and teardown validation closes on the Haskell stack.
- The destructive lifecycle and aggregate runner preserve the supported credential-recovery rules.
- The operator docs for account setup, ACME provider choice, and elevated credential handling are
  aligned with the Haskell implementation.

### Validation

1. `prodbox test integration aws-iam`
2. `prodbox test all`

### Current Validation State

- The isolated `aws_admin` config contract and the Haskell IAM runtime surface are implemented in
  `src/Prodbox/Settings.hs` and `src/Prodbox/Aws.hs`.
- `src/Prodbox/TestPlan.hs` maps `prodbox test integration aws-iam` to an executable native
  validation flow in `src/Prodbox/TestValidation.hs`.
- `prodbox test all` now includes that native IAM payload as part of the aggregate validation
  harness instead of a pending placeholder failure.

### Remaining Work

None.

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
- `documents/engineering/unit_testing_policy.md` - reopened IAM lifecycle proof ownership on the
  Haskell stack.

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
