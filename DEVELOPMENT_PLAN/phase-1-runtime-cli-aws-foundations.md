# File: DEVELOPMENT_PLAN/phase-1-runtime-cli-aws-foundations.md
# Phase 1: Runtime, CLI, and AWS Validation Foundations

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [system-components.md](system-components.md)

> **Purpose**: Capture the runtime, CLI, and AWS-auth foundations that make later gateway, chart,
> and public-host phases meaningful and testable.

## Phase Summary

This phase establishes one explicit CLI surface, one named test-command surface, one
supported-host gate, one host-owned RKE2 install/delete lifecycle, one repository-root AWS
auth/config source, and one authoritative real-system validation baseline for AWS-backed
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
**Implementation**: `src/prodbox/settings.py`, `src/prodbox/lib/aws_auth.py` (removed in Sprint 4.8), `src/prodbox/cli/pulumi_cmd.py`, `tests/integration/test_aws_foundation_real.py`, `tests/integration/test_aws_eks_real.py`, `tests/integration/test_dns_route53_aws.py`, `tests/integration/test_pulumi_real.py`
**Docs to update**: `documents/engineering/README.md`, `documents/engineering/aws_integration_environment_doctrine.md`, `documents/engineering/aws_test_environment.md`, `documents/engineering/integration_fixture_doctrine.md`, `documents/engineering/unit_testing_policy.md`

### Objective

Establish one canonical AWS auth source and authoritative real-system validation for AWS-backed
surfaces.

### Deliverables

- Repository-root `prodbox-config.dhall` (compiled to `prodbox-config.json` and read by
  `Settings.from_config_json()`) is the only supported AWS auth source for stateful integration
  runs. Phase 4 later replaced the original `.env`-based source with this Dhall path; Sprint 1.2
  is the sprint that originally established the single-source rule.
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


## Sprint 1.3: Supported Host Gate and Host-Owned RKE2 Cluster Lifecycle ✅

**Status**: Done
**Implementation**: `src/prodbox/cli/rke2.py`, `src/prodbox/cli/dag_builders.py`, `src/prodbox/cli/interpreter.py`, `src/prodbox/cli/prerequisite_registry.py`, `src/prodbox/settings.py`, `tests/integration/test_prodbox_lifecycle.py`, `tests/integration/test_cli_commands.py`
**Docs to update**: `documents/engineering/cli_command_surface.md`, `documents/engineering/effectful_dag_architecture.md`, `documents/engineering/prerequisite_doctrine.md`, `documents/engineering/storage_lifecycle_doctrine.md`

### Objective

Make `prodbox` the owner of the RKE2 cluster lifecycle itself on the only supported host platform,
`Ubuntu 24.04 LTS`.

### Deliverables

- `prodbox rke2 install` installs the cluster substrate, enables the systemd resources needed for
  RKE2 restart after reboot, and leaves the host in the canonical supported state.
- `prodbox rke2 delete --yes` becomes the destructive cluster-removal surface; the old
  preinstalled-cluster assumption is no longer part of the supported architecture.
- Unsupported hosts fail fast before lifecycle commands run; `Ubuntu 24.04 LTS` is the only
  supported operator environment.
- Lifecycle prerequisites and summaries describe cluster install/delete ownership instead of
  assuming `/usr/local/bin/rke2` and `/etc/rancher/rke2/config.yaml` already exist.

### Validation

1. `poetry run prodbox check-code`
2. `poetry run prodbox test unit`
3. `poetry run prodbox test integration cli`
4. `poetry run prodbox test integration lifecycle`
5. Supported-host install proof on Ubuntu 24.04: `poetry run prodbox rke2 install`
6. Systemd enablement proof on Ubuntu 24.04: `systemctl is-enabled rke2-server`

### Closure Validation (2026-04-13)

- `poetry run prodbox rke2 delete --yes` passed on April 13, 2026 and reported preserved roots
  `/home/matthewnowak/prodbox/.data` and `/home/matthewnowak/prodbox/.prodbox-state`.
- `poetry run prodbox rke2 install` passed on April 13, 2026 in `6m 40s` on
  `Ubuntu 24.04.4 LTS`.
- `systemctl is-enabled rke2-server` returned `enabled`, proving reboot-time ownership is now part
  of the supported lifecycle.
- `poetry run prodbox test integration cli`, the lifecycle suite inside `poetry run prodbox test all`,
  and `poetry run prodbox check-code` all passed on April 13, 2026 after the host-owned lifecycle
  closure work.

### Remaining Work

None.

## Documentation Requirements

**Engineering docs to create/update:**

- `documents/engineering/cli_command_surface.md` - canonical command matrix and test-command
  ownership.
- `documents/engineering/prerequisite_doctrine.md` - prerequisite closure rules and Ubuntu 24.04 support gate.
- `documents/engineering/unit_testing_policy.md` - named test-suite and validation ownership.
- `documents/engineering/effectful_dag_architecture.md` - host-owned cluster install/delete ordering.
- `documents/engineering/storage_lifecycle_doctrine.md` - lifecycle boundary between full cluster delete and preserved PV content root.
- `documents/engineering/aws_integration_environment_doctrine.md` - repository-root
  `prodbox-config.dhall` auth source (compiled to `prodbox-config.json`) and AWS cleanup rules.
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
