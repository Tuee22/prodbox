# File: DEVELOPMENT_PLAN/phase-1-runtime-cli-aws-foundations.md
# Phase 1: Runtime, CLI, and AWS Validation Foundations

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [system-components.md](system-components.md)

> **Purpose**: Capture the runtime, CLI, and AWS-auth foundations that make later gateway, chart,
> and public-host phases meaningful and testable.

## Phase Summary

This phase establishes one explicit CLI surface, one named test-command surface, one
supported-host gate, one host-owned local RKE2 install/delete lifecycle, one repository-root AWS
auth and config source, one local-cluster-first MinIO backend for Pulumi test state, and one
authoritative AWS validation baseline that closes only when `prodbox` supports both intended
AWS-backed cluster validation patterns: an EKS-backed path and an HA RKE2 path over SSH onto
three separate-AZ `Ubuntu 24.04 LTS` EC2 instances. Both paths are now implemented in the
worktree and validated on the supported baseline, including the April 15, 2026 destructive rerun
from `prodbox rke2 delete --yes`, a pruned Docker baseline, and a removed `.data/` root.

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
**Implementation**: `src/prodbox/settings.py`, `src/prodbox/cli/pulumi_cmd.py`, `tests/integration/aws_helpers.py`, `tests/integration/test_dns_route53_aws.py`, `tests/integration/test_pulumi_real.py`
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
3. `poetry run prodbox test integration dns-aws`
4. `poetry run prodbox test integration pulumi`

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

## Sprint 1.4: SSH-Driven HA RKE2 on Pulumi-Managed Ubuntu 24.04 EC2 Nodes ✅

**Status**: Done
**Implementation**: `src/prodbox/cli/command_adt.py`, `src/prodbox/cli/pulumi_cmd.py`, `src/prodbox/cli/dag_builders.py`, `src/prodbox/infra/aws_test_stack_program.py`, `src/prodbox/lib/aws_test_stack.py`, `src/prodbox/lib/ha_rke2_aws.py`, `tests/integration/test_ha_rke2_aws.py`, `tests/integration/test_pulumi_real.py`
**Docs to update**: `documents/engineering/aws_integration_environment_doctrine.md`, `documents/engineering/aws_test_environment.md`, `documents/engineering/cli_command_surface.md`, `documents/engineering/effectful_dag_architecture.md`, `documents/engineering/prerequisite_doctrine.md`, `documents/engineering/unit_testing_policy.md`

### Objective

Add the HA RKE2 AWS deployment and validation path alongside the intended EKS-backed path instead
of treating it as a replacement.

### Deliverables

- Pulumi provisions exactly three `Ubuntu 24.04 LTS` EC2 instances in separate AZs, plus the VPC,
  subnet, security-group, IAM, and Route 53 prerequisites needed for the supported test stack.
- `prodbox` owns the SSH-driven HA RKE2 bootstrap and join sequence across those three nodes as
  one AWS-backed cluster validation pattern.
- The host machine running the tests boots the local RKE2 cluster first, runs MinIO there, and
  provides the Pulumi backend before any remote AWS test resources are created.
- The Pulumi backend uses one dedicated MinIO bucket named `prodbox-test-pulumi-backends` so test
  backend leakage is easy to spot.
- A named integration suite, `poetry run prodbox test integration ha-rke2-aws`, provisions the
  AWS test stack, installs HA RKE2 over SSH, validates cluster readiness, and returns a destroyable
  test environment owned by Pulumi.

### Validation

1. `poetry run prodbox rke2 delete --yes`
2. `rm -f prodbox-config.json`
3. `poetry run prodbox rke2 install`
4. `poetry run prodbox config show`
5. `poetry run prodbox config validate`
6. `poetry run prodbox pulumi test-resources`
7. `poetry run prodbox test integration ha-rke2-aws`
8. `poetry run prodbox pulumi test-destroy --yes`
9. `poetry run prodbox check-code`

### Current Validation State

- `poetry run prodbox check-code` passed on April 14, 2026.
- `poetry run prodbox test unit` passed on April 14, 2026 (`989 passed`).
- `poetry run prodbox rke2 delete --yes`, `rm -f prodbox-config.json`, `poetry run prodbox rke2 install`, `poetry run prodbox config show`, and `poetry run prodbox config validate` passed on April 13, 2026 from the missing compiled-config baseline.
- `poetry run prodbox pulumi test-resources` passed on April 14, 2026 and created the canonical `aws-test` stack with three Pulumi-managed EC2 nodes in separate AZs.
- The same HA-over-SSH proof executed by `poetry run prodbox test integration ha-rke2-aws` passed inside the canonical `poetry run prodbox test all` rerun on April 14, 2026 as `tests/integration/test_ha_rke2_aws.py::test_ha_rke2_bootstrap_succeeds_on_three_pulumi_managed_nodes`.
- `poetry run prodbox pulumi test-destroy --yes` passed on April 14, 2026 and verified no AWS residue plus an empty backend bucket `prodbox-test-pulumi-backends`.
- `poetry run prodbox rke2 delete --yes` passed again on April 14, 2026 and auto-ran the shared Pulumi destroy path before local backend teardown.
- These validations closed the HA RKE2 branch first; Sprint 1.5 later added the companion
  EKS-backed `prodbox` command surface and closed the full dual-path posture on April 15, 2026.

### Remaining Work

None.

## Sprint 1.5: EKS-Backed AWS Deployment and Validation Path ✅

**Status**: Done
**Implementation**: `src/prodbox/cli/pulumi_cmd.py`, `src/prodbox/cli/dag_builders.py`, `src/prodbox/infra/aws_eks_test_stack_program.py`, `src/prodbox/lib/aws_eks_test_stack.py`, `pulumi/aws-eks/`, `src/prodbox/cli/test_cmd.py`, `tests/integration/test_aws_eks.py`, `tests/unit/test_aws_eks_test_stack.py`, `tests/unit/test_aws_eks_test_stack_program.py`
**Docs to update**: `documents/engineering/aws_integration_environment_doctrine.md`, `documents/engineering/aws_test_environment.md`, `documents/engineering/cli_command_surface.md`, `documents/engineering/effectful_dag_architecture.md`, `documents/engineering/unit_testing_policy.md`

### Objective

Close the intended EKS-backed AWS deployment and validation path so `prodbox` supports both EKS
and HA RKE2 for AWS-backed cluster validation.

### Deliverables

- `prodbox` exposes the named EKS-backed AWS cluster lifecycle surfaces
  `prodbox pulumi eks-resources` and `prodbox pulumi eks-destroy --yes` under the supported CLI.
- The AWS validation posture becomes explicitly dual-path: one EKS-backed path and one HA RKE2
  path. Neither path is treated as a replacement for the other.
- The EKS path uses the same repository-root Dhall auth source, local-cluster-first Pulumi
  backend, and explicit cleanup doctrine as the HA RKE2 path.
- A named integration suite, `poetry run prodbox test integration aws-eks`, proves the EKS-backed
  path end to end and becomes part of the governed test-command surface.
- `prodbox rke2 delete --yes` now destroys the EKS stack before the HA RKE2 stack so the shared
  local MinIO backend can be torn down without leaving Pulumi-managed AWS residue behind.

### Validation

1. `poetry run prodbox check-code`
2. `poetry run prodbox test unit`
3. `poetry run prodbox test integration aws-eks`
4. The canonical EKS provision and destroy surfaces under `prodbox` succeed from a clean backend
   baseline.

### Current Validation State

- `src/prodbox/cli/pulumi_cmd.py` now exposes `prodbox pulumi eks-resources` and
  `prodbox pulumi eks-destroy --yes`, each guarded by the same operational-credential harness as
  the existing HA RKE2 stack surfaces.
- `src/prodbox/infra/aws_eks_test_stack_program.py` now provisions the dedicated Pulumi-managed
  EKS validation stack: one VPC, two public subnets across two AZs, one EKS control plane, one
  managed node group, and the required IAM roles and policy attachments.
- `src/prodbox/lib/aws_eks_test_stack.py` now owns EKS stack snapshot persistence, cluster
  validation, residue checks, and idempotent destroy semantics against the shared backend bucket
  `prodbox-test-pulumi-backends`.
- `src/prodbox/cli/test_cmd.py` now exposes the named `aws-eks` suite and includes
  `tests/integration/test_aws_eks.py` in the canonical aggregate ordering before the existing HA
  stack proofs.
- `src/prodbox/cli/dag_builders.py` now prepends `pulumi eks-destroy --yes` before
  `pulumi test-destroy --yes` during `prodbox rke2 delete --yes`.
- `poetry run prodbox check-code` passed on April 15, 2026 after the final
  status-documentation refresh.
- `poetry run prodbox test unit` passed on April 15, 2026 (`1075 passed`) with the EKS command
  ADTs, DAGs, helpers, CLI surface, Pulumi program, and policy-repair flow covered.
- `poetry run prodbox pulumi eks-resources`, `poetry run prodbox test integration aws-eks`, and
  `poetry run prodbox pulumi eks-destroy --yes` passed on April 15, 2026; the named EKS suite
  `tests/integration/test_aws_eks.py` passed (`1 passed` in `22m 03s`).
- The April 15, 2026 destructive rerun from `poetry run prodbox rke2 delete --yes`,
  `docker system prune -af --volumes`, `sudo rm -rf .data`, and `poetry run prodbox test all`
  passed in `1h 49m 7s`, included `tests/integration/test_aws_eks.py`, restored the supported
  runtime to `CLASSIFICATION=ready-for-external-proof`, and auto-destroyed both `aws-eks-test`
  and `aws-test` with no residue.

### Remaining Work

None.

## Documentation Requirements

**Engineering docs to create/update:**

- `documents/engineering/cli_command_surface.md` - canonical command matrix, test-command
  ownership, and Pulumi test-resource inspection and destroy surfaces.
- `documents/engineering/prerequisite_doctrine.md` - prerequisite closure rules and Ubuntu 24.04 support gate.
- `documents/engineering/unit_testing_policy.md` - named test-suite and validation ownership.
- `documents/engineering/effectful_dag_architecture.md` - local cluster install/delete
  ordering plus remote HA-over-SSH sequencing.
- `documents/engineering/storage_lifecycle_doctrine.md` - lifecycle boundary between full cluster delete and preserved PV content root.
- `documents/engineering/aws_integration_environment_doctrine.md` - repository-root
  `prodbox-config.dhall` auth source (compiled to `prodbox-config.json`), the local-cluster-first
  MinIO backend, and Pulumi-exclusive AWS provisioning and teardown rules.
- `documents/engineering/aws_test_environment.md` - local MinIO backend plus the three-node,
  separate-AZ `Ubuntu 24.04 LTS` AWS test environment setup.
- `documents/engineering/integration_fixture_doctrine.md` - replacement of tag-sweep fixture
  cleanup with Pulumi-owned AWS test-stack teardown ordering.

**Product docs to create/update:**

- None.

**Cross-references to add:**

- Keep `README.md` and `documents/engineering/README.md` aligned with the canonical plan entrypoint
  and phase names.

## Related Documents

- [README.md](README.md)
- [00-overview.md](00-overview.md)
- [system-components.md](system-components.md)
