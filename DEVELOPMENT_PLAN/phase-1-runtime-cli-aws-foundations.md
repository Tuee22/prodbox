# File: DEVELOPMENT_PLAN/phase-1-runtime-cli-aws-foundations.md
# Phase 1: Runtime, CLI, and AWS Validation Foundations

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [system-components.md](system-components.md)

> **Purpose**: Capture the runtime, CLI, and AWS-auth foundations that make later gateway, chart,
> and public-host phases meaningful and testable.

## Phase Summary

This phase establishes one explicit CLI surface, one named test-command surface, one repository-root
AWS auth/config source, and one authoritative real-system validation baseline for AWS-backed
surfaces.

## Sprint 1.1: Runtime, CLI, and Test-Command Foundations ✅

**Status**: Done
**Implementation**: `src/prodbox/cli/main.py`, `src/prodbox/cli/test_cmd.py`, `src/prodbox/cli/command_adt.py`, `src/prodbox/cli/dag_builders.py`, `tests/integration/test_cli_commands.py`, `tests/integration/test_cli_env.py`
**Docs to update**: `documents/engineering/README.md`, `documents/engineering/cli_command_surface.md`, `documents/engineering/prerequisite_doctrine.md`, `documents/engineering/unit_testing_policy.md`

### Objective

Establish one explicit public CLI surface and one explicit named test-command surface.

### Deliverables

- Inert runtime placeholders and prerequisite shortcuts are removed.
- The implemented Click surface matches the documented command matrix.
- `prodbox test` exposes named suites only.
- Documentation anchors, backlinks, and click-passthrough rules are enforced by automation.

### Validation

1. `poetry run prodbox check-code`
2. `poetry run prodbox test unit`
3. `poetry run prodbox test integration cli`
4. `poetry run prodbox test integration env`

### Remaining Work

None.

## Sprint 1.2: AWS Auth Doctrine and Real-System Validation Foundation ✅

**Status**: Done
**Implementation**: `src/prodbox/settings.py`, `src/prodbox/lib/aws_auth.py`, `src/prodbox/cli/pulumi_cmd.py`, `tests/integration/test_aws_foundation_real.py`, `tests/integration/test_aws_eks_real.py`, `tests/integration/test_dns_route53_aws.py`, `tests/integration/test_pulumi_real.py`
**Docs to update**: `documents/engineering/README.md`, `documents/engineering/aws_integration_environment_doctrine.md`, `documents/engineering/aws_test_environment.md`, `documents/engineering/integration_fixture_doctrine.md`, `documents/engineering/unit_testing_policy.md`

### Objective

Establish one canonical AWS auth source and authoritative real-system validation for AWS-backed
surfaces.

### Deliverables

- Repository-root `.env` is the only supported AWS auth source for stateful integration runs.
- Named AWS, Route 53, and Pulumi real-system suites exist and are stable.
- Teardown and cleanup validation are explicit rather than implied.
- Pulumi integration runs use an isolated local backend plus a fixture-owned hosted zone.

### Validation

1. `poetry run prodbox check-code`
2. `poetry run prodbox test unit`
3. `poetry run prodbox test integration aws-foundation`
4. `poetry run prodbox test integration aws-eks`
5. `poetry run prodbox test integration dns-aws`
6. `poetry run prodbox test integration pulumi`

### Remaining Work

None.

## Documentation Requirements

**Engineering docs to create/update:**

- `documents/engineering/cli_command_surface.md` - canonical command matrix and test-command
  ownership.
- `documents/engineering/prerequisite_doctrine.md` - prerequisite closure rules.
- `documents/engineering/unit_testing_policy.md` - named test-suite and validation ownership.
- `documents/engineering/aws_integration_environment_doctrine.md` - repository-root `.env` auth and
  AWS cleanup rules.
- `documents/engineering/aws_test_environment.md` - shared AWS environment setup.
- `documents/engineering/integration_fixture_doctrine.md` - fixture-owned teardown and cleanup
  doctrine.

**Product docs to create/update:**

- None.

**Cross-references to add:**

- Keep `README.md` and `documents/engineering/README.md` aligned with the canonical plan entrypoint
  and phase names.

## Related Documents

- [README.md](README.md)
- [00-overview.md](00-overview.md)
- [system-components.md](system-components.md)
