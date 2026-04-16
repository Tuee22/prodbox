# Phase 7: Interactive Onboarding, AWS IAM, and Quota Automation in Haskell

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [00-overview.md](00-overview.md), [system-components.md](system-components.md)

> **Purpose**: Define the supported Haskell onboarding wizard, standalone AWS IAM and quota command
> surface, and the elevated-credential validation harness for real IAM lifecycle proof.

## Phase Summary

This phase ports the highest-friction operator flows to Haskell: interactive config authoring,
policy generation, IAM user management, service-quota automation, and the test-only elevated
credential harness. It closes only when the operator no longer needs Python for any supported AWS
administration or onboarding path.

## Sprint 7.1: Interactive Configuration Wizard and Policy Generation in Haskell 📋

**Status**: Planned
**Implementation**: `src/Prodbox/CLI/Config.hs`, `src/Prodbox/CLI/Aws.hs`, `src/Prodbox/Lib/AwsAdmin.hs`, `test/unit/aws_admin/`
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

### Remaining Work

- All deliverables remain open.

## Sprint 7.2: Standalone IAM Lifecycle and Quota Automation in Haskell 📋

**Status**: Planned
**Implementation**: `src/Prodbox/CLI/Aws.hs`, `src/Prodbox/Lib/AwsAdmin.hs`, `test/unit/aws_admin/`, `test/integration/aws_iam/`
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

### Remaining Work

- All deliverables remain open.

## Sprint 7.3: Elevated Credential Harness and Real IAM Lifecycle Proof on the Haskell Stack 📋

**Status**: Planned
**Implementation**: `src/Prodbox/Settings.hs`, `src/Prodbox/Lib/AwsAdmin.hs`, `test/integration/aws_iam/`
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

### Remaining Work

- All deliverables remain open.

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
- `documents/engineering/unit_testing_policy.md` - real IAM lifecycle proof on the Haskell stack.

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
