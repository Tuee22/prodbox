# File: DEVELOPMENT_PLAN/phase-7-aws-iam-quota-automation.md
# Phase 7: Interactive Onboarding, AWS IAM, and Quota Automation

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [00-overview.md](00-overview.md), [system-components.md](system-components.md)

> **Purpose**: Define the supported interactive onboarding wizard, standalone AWS IAM and quota
> command surface, and the elevated-credential validation harness for real IAM lifecycle proof.

## Phase Summary

This phase defines the supported zero-to-config onboarding and AWS-account automation path.
`prodbox config setup` owns interactive Dhall authoring, `prodbox aws *` owns standalone IAM and
quota automation, and the repository Dhall schema carries a separate `aws_admin` section for
elevated test-only credentials. The interactive prompts explain where to create the temporary
elevated access key in the AWS console and how to choose the supported region, hosted zone, ACME
provider, and policy tier. The aggregate runner plus destructive lifecycle helpers restore blank
operational `aws.*` credentials from raw-config `aws_admin.*` and refresh the supported-runtime
Pulumi AWS provider state before EC2-backed validation continues. `prodbox config setup` is the
only supported onboarding path; no legacy `.env` migration shim remains on the public CLI surface.

---

## Sprint 7.1: IAM Policy Generation and `prodbox aws policy` ✅

**Status**: Done
**Implementation**: `src/prodbox/cli/aws_cmd.py`, `src/prodbox/cli/command_adt.py`, `src/prodbox/cli/dag_builders.py`, `src/prodbox/lib/aws_admin.py`, `tests/unit/test_phase7_commands.py`, `tests/integration/test_cli_commands.py`
**Docs to update**: `documents/engineering/cli_command_surface.md`

### Objective

Provide a pure command that emits the supported operational inline-policy JSON with no credential
dependency and no appended success summary.

### Deliverables

1. `prodbox aws policy [--tier core|full]` exists on the supported CLI surface.
2. Core tier emits the STS identity statement plus the Route 53 record-management and change-polling
   statements required by the supported architecture.
3. Full tier adds hosted-zone lifecycle plus the HA RKE2 and EKS AWS test-stack lifecycle
   statements, including the IAM role and `eks:*` actions required by the supported architecture.
4. The command uses the command ADT plus DAG path and renders machine-parseable JSON only.

### Validation

- `tests/unit/test_phase7_commands.py` covers the smart constructor, DAG shape, and success-summary
  suppression behavior.
- `tests/integration/test_cli_commands.py::test_aws_policy_outputs_parseable_json_without_summary`
  passed on April 14, 2026.

### Remaining Work

None.

---

## Sprint 7.2: Interactive Configuration Wizard ✅

**Status**: Done
**Implementation**: `src/prodbox/cli/config_cmd.py`, `src/prodbox/cli/command_adt.py`, `src/prodbox/cli/dag_builders.py`, `src/prodbox/lib/aws_admin.py`, `tests/unit/test_aws_admin.py`, `documents/engineering/aws_account_setup_guide.md`, `documents/engineering/acme_provider_guide.md`, `README.md`
**Docs to update**: `documents/engineering/aws_account_setup_guide.md`, `documents/engineering/acme_provider_guide.md`, `documents/engineering/cli_command_surface.md`, `README.md`

### Objective

Make `prodbox config setup` the supported onboarding path instead of manual credential editing and
manual Dhall authoring.

### Deliverables

1. The wizard prompts for temporary elevated AWS credentials with clear AWS-console guidance and
   without persisting them.
2. Region and Route 53 zone selection are driven by live AWS CLI queries.
3. The flow provides AWS account creation guidance, ACME provider guidance, domain defaults,
   deployment defaults, and manual PV host-root defaults.
4. The wizard creates or refreshes the dedicated `prodbox` IAM user, writes
   `prodbox-config.dhall`, compiles it, validates it, and prints post-setup guidance to delete the
   temporary elevated key.

### Validation

- `tests/unit/test_phase7_commands.py` and `tests/unit/test_aws_admin.py` cover command validation,
  interactive collection helpers, AWS-console prompt guidance, Dhall writing, and render output.
- The supporting operator documentation now lives in
  `documents/engineering/aws_account_setup_guide.md`,
  `documents/engineering/acme_provider_guide.md`, and `README.md`.

### Remaining Work

None.

---

## Sprint 7.3: Standalone IAM User Lifecycle ✅

**Status**: Done
**Implementation**: `src/prodbox/cli/aws_cmd.py`, `src/prodbox/cli/command_adt.py`, `src/prodbox/cli/dag_builders.py`, `src/prodbox/lib/aws_admin.py`, `tests/unit/test_aws_admin.py`
**Docs to update**: `documents/engineering/cli_command_surface.md`

### Objective

Provide standalone `prodbox aws setup` and `prodbox aws teardown` surfaces for managing the
supported operational IAM user outside the full onboarding wizard.

### Deliverables

1. `prodbox aws setup [--tier core|full]` creates or refreshes the `prodbox` IAM user, rotates
   access keys, writes `aws.*` in Dhall config, and validates the result.
2. `prodbox aws teardown` deletes all access keys, removes the inline policy, deletes the IAM user
   when present, clears `aws.*`, and recompiles config.
3. The lifecycle is idempotent for `EntityAlreadyExists` and `NoSuchEntity`.
4. All AWS calls run through the AWS CLI with explicit subprocess environments, not boto3 and not
   host AWS profile discovery.

### Validation

- `tests/unit/test_aws_admin.py` covers setup success, teardown success, missing-user handling, and
  validation-failure reporting.
- `documents/engineering/cli_command_surface.md` now documents the standalone IAM lifecycle
  commands.

### Remaining Work

None.

---

## Sprint 7.4: Service Quota Inspection and Request Automation ✅

**Status**: Done
**Implementation**: `src/prodbox/cli/aws_cmd.py`, `src/prodbox/cli/command_adt.py`, `src/prodbox/cli/dag_builders.py`, `src/prodbox/lib/aws_admin.py`, `tests/unit/test_aws_admin.py`
**Docs to update**: `documents/engineering/cli_command_surface.md`

### Objective

Provide explicit CLI surfaces for inspecting and requesting the supported AWS service quotas needed
by the architecture.

### Deliverables

1. `prodbox aws check-quotas` renders the supported quota table from live AWS CLI calls.
2. `prodbox aws request-quotas [--tier core|full]` requests only the quota increases still below
   target.
3. The supported quota set includes Standard vCPU, VPCs, internet gateways, Elastic IPs, security
   groups, hosted zones, and subnets per VPC.
4. The command surface uses the ADT plus DAG path and renders structured tabular output.

### Validation

- `tests/unit/test_phase7_commands.py` covers the quota-command ADTs and DAG shapes.
- `tests/unit/test_aws_admin.py` covers quota parsing, fallback behavior, and request delegation.

### Remaining Work

None.

---

## Sprint 7.5: Elevated Credential Harness and Full IAM Lifecycle Validation ✅

**Status**: Done
**Implementation**: `prodbox-config-types.dhall`, `src/prodbox/settings.py`, `tests/integration/test_aws_iam_lifecycle.py`, `documents/engineering/aws_admin_credentials.md`
**Docs to update**: `documents/engineering/aws_admin_credentials.md`, `documents/engineering/aws_account_setup_guide.md`, `documents/engineering/acme_provider_guide.md`

### Objective

Prove the real IAM lifecycle end to end using elevated test-only credentials isolated from the
normal operational `aws.*` section.

### Deliverables

1. `prodbox-config-types.dhall` defines `aws_admin` with the same field shape as `aws`.
2. `Settings` exposes optional `aws_admin_*` fields and enforces the all-or-nothing invariant for
   access key, secret, and region.
3. Normal runtime commands continue to read only `aws.*`; the elevated section is reserved for
   `prodbox aws *` and `prodbox test integration aws-iam`.
4. `tests/integration/test_aws_iam_lifecycle.py` contains the real AWS setup/teardown round-trip
   proof plus the interactive `config setup` flow proof.
5. The operator docs for the elevated harness, AWS account creation, and ACME provider selection
   are now present under `documents/engineering/`.

### Current Validation State

- `poetry run prodbox check-code` passed on April 15, 2026 after the destructive-rerun fixes and
  Phase 7 status-documentation refresh.
- `poetry run prodbox test unit` passed on April 15, 2026 (`1078 passed`).
- `poetry run prodbox test integration aws-iam` passed on April 14, 2026 (`2 passed`).
- The April 15, 2026 destructive rerun from `poetry run prodbox rke2 delete --yes`,
  `docker system prune -af --volumes`, `sudo rm -rf .data`, and `poetry run prodbox test all`
  passed in `1h 42m 48s`; the aggregate rerun included `tests/integration/test_aws_eks.py`,
  `tests/integration/test_pulumi_real.py`, `tests/integration/test_ha_rke2_aws.py`,
  `tests/integration/test_gateway_k8s_pods.py`, `tests/integration/test_charts_platform.py`,
  `tests/integration/test_prodbox_lifecycle.py`, and `tests/integration/test_aws_iam_lifecycle.py`,
  restored the supported runtime after the destructive IAM suite, reached
  `CLASSIFICATION=ready-for-external-proof`, and proved that blank operational `aws.*`
  credentials recover from raw-config `aws_admin.*` during clean-room validation while the
  supported-runtime repair advances stale Pulumi AWS provider state before post-IAM restore.

### Remaining Work

None.

---

## Documentation Requirements

**Engineering docs to create/update:**
- `documents/engineering/aws_account_setup_guide.md` - created for AWS account creation, Free Tier,
  hosted-zone preparation, and temporary elevated-key workflow
- `documents/engineering/aws_admin_credentials.md` - created for the `aws_admin` harness and
  cleanup rules
- `documents/engineering/acme_provider_guide.md` - created for ZeroSSL vs Let's Encrypt selection
- `documents/engineering/cli_command_surface.md` - updated for `config setup`, `aws *`, and
  `test integration aws-iam`
- `documents/engineering/aws_integration_environment_doctrine.md` - updated for the test-only
  elevated credential harness

**Product docs to create/update:**
- `README.md` - updated for the supported onboarding path and new AWS command surface

**Cross-references to add:**
- `documents/engineering/README.md`
- `documents/engineering/aws_integration_environment_doctrine.md`

## Related Documents

- [README.md](README.md)
- [00-overview.md](00-overview.md)
- [system-components.md](system-components.md)
- [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md)
- [../documents/engineering/aws_account_setup_guide.md](../documents/engineering/aws_account_setup_guide.md)
- [../documents/engineering/aws_admin_credentials.md](../documents/engineering/aws_admin_credentials.md)
- [../documents/engineering/acme_provider_guide.md](../documents/engineering/acme_provider_guide.md)
- [../documents/engineering/aws_integration_environment_doctrine.md](../documents/engineering/aws_integration_environment_doctrine.md)
- [../documents/engineering/cli_command_surface.md](../documents/engineering/cli_command_surface.md)
