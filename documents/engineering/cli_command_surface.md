# CLI Command Surface

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: README.md, AGENTS.md, CLAUDE.md, DEVELOPMENT_PLAN/README.md, DEVELOPMENT_PLAN/system-components.md, documents/engineering/README.md, documents/engineering/acme_provider_guide.md, documents/engineering/aws_account_setup_guide.md, documents/engineering/aws_admin_credentials.md, documents/engineering/aws_integration_environment_doctrine.md, documents/engineering/dependency_management.md, documents/engineering/unit_testing_policy.md, documents/engineering/helm_chart_platform_doctrine.md

> **Purpose**: Define the explicit, no-passthrough Click command surface for `prodbox`.

---

## 1. Command Surface Statement

prodbox CLI commands accept only explicitly declared Click arguments and options; passthrough to downstream tools is prohibited.

The CLI surface is intentionally closed:

1. Unknown extra arguments fail at the Click boundary.
2. Invoking a command group without a subcommand displays help instead of running an implicit default.
3. Every supported test subset is exposed as a named Click command, not as raw pytest selectors.

This document defines the supported command contract only. Clean-room
sequencing, completion status, remaining work, and legacy-path removal are
owned by [DEVELOPMENT_PLAN/README.md](../../DEVELOPMENT_PLAN/README.md).

---

## 2. Global Surface

Top-level invocation:

```text
prodbox [--verbose|-v] [--version] <command> ...
```

Top-level commands:

| Command | Kind | Purpose |
|---------|------|---------|
| `aws` | Group | IAM policy, IAM user lifecycle, and service quota management |
| `config` | Group | Dhall configuration management |
| `host` | Group | Host prerequisite checks |
| `rke2` | Group | Local cluster lifecycle |
| `pulumi` | Group | Infrastructure deployment |
| `dns` | Group | Route 53 inspection |
| `k8s` | Group | Kubernetes health and log utilities |
| `gateway` | Group | Gateway daemon operations |
| `charts` | Group | Bespoke Helm chart lifecycle |
| `test` | Group | Explicit named test suites |
| `check-code` | Command | Policy guards + `ruff` + `mypy` |
| `tla-check` | Command | TLA+ model checking via Docker |

---

## 3. Command Matrix

### `prodbox config`

| Command | Arguments | Options |
|---------|-----------|---------|
| `prodbox config compile` | none | none |
| `prodbox config setup` | none | none |
| `prodbox config show` | none | `--show-secrets` |
| `prodbox config validate` | none | none |

### `prodbox aws`

| Command | Arguments | Options |
|---------|-----------|---------|
| `prodbox aws policy` | none | `--tier` |
| `prodbox aws setup` | none | `--tier` |
| `prodbox aws teardown` | none | none |
| `prodbox aws check-quotas` | none | none |
| `prodbox aws request-quotas` | none | `--tier` |

### `prodbox host`

| Command | Arguments | Options |
|---------|-----------|---------|
| `prodbox host ensure-tools` | none | none |
| `prodbox host check-ports` | none | none |
| `prodbox host info` | none | none |
| `prodbox host firewall` | none | none |
| `prodbox host public-edge` | none | none |

### `prodbox rke2`

| Command | Arguments | Options |
|---------|-----------|---------|
| `prodbox rke2 status` | none | none |
| `prodbox rke2 start` | none | none |
| `prodbox rke2 stop` | none | none |
| `prodbox rke2 restart` | none | none |
| `prodbox rke2 install` | none | none |
| `prodbox rke2 delete` | none | `--yes` |
| `prodbox rke2 logs` | none | `--lines`, `-n` |

### `prodbox pulumi`

| Command | Arguments | Options |
|---------|-----------|---------|
| `prodbox pulumi up` | none | `--yes`, `-y` |
| `prodbox pulumi destroy` | none | `--yes`, `-y` |
| `prodbox pulumi preview` | none | none |
| `prodbox pulumi refresh` | none | none |
| `prodbox pulumi stack-init` | `STACK` | none |
| `prodbox pulumi eks-resources` | none | none |
| `prodbox pulumi eks-destroy` | none | `--yes`, `-y` |
| `prodbox pulumi test-resources` | none | none |
| `prodbox pulumi test-destroy` | none | `--yes`, `-y` |

### `prodbox dns`

| Command | Arguments | Options |
|---------|-----------|---------|
| `prodbox dns check` | none | none |

### `prodbox k8s`

| Command | Arguments | Options |
|---------|-----------|---------|
| `prodbox k8s health` | none | none |
| `prodbox k8s wait` | none | `--timeout`, `-t`, `--namespace`, `-n` |
| `prodbox k8s logs` | none | `--namespace`, `-n`, `--tail` |

### `prodbox gateway`

| Command | Arguments | Options |
|---------|-----------|---------|
| `prodbox gateway start` | `CONFIG_PATH` | none |
| `prodbox gateway status` | `CONFIG_PATH` | none |
| `prodbox gateway config-gen` | `OUTPUT_PATH` | `--node-id` |

The canonical steady-state location for the gateway daemon is the in-cluster
`prodbox charts deploy gateway` workload. `prodbox gateway start` is the in-pod
entrypoint invoked by the gateway chart's container; manual host invocation is
permitted only for development and is not a supported steady state.

### `prodbox charts`

| Command | Arguments | Options |
|---------|-----------|---------|
| `prodbox charts list` | none | none |
| `prodbox charts status` | `CHART` | none |
| `prodbox charts deploy` | `CHART` | none |
| `prodbox charts delete` | `CHART` | `--yes`, `-y` |

### `prodbox test`

`prodbox test` and `prodbox test integration` are help groups only. They do not run an implicit default suite.

Shared executable-suite options:

| Option | Meaning |
|--------|---------|
| `--coverage` | Add `pytest-cov` for `src/prodbox` |
| `--cov-fail-under INTEGER` | Require a minimum coverage percentage; valid only with `--coverage` |

Named suite commands:

| Command | Scope |
|---------|-------|
| `prodbox test all` | `tests/unit` + `tests/integration` |
| `prodbox test unit` | `tests/unit` |
| `prodbox test integration all` | `tests/integration` |
| `prodbox test integration cli` | `tests/integration/test_cli_commands.py` |
| `prodbox test integration aws-iam` | `tests/integration/test_aws_iam_lifecycle.py` |
| `prodbox test integration dns-aws` | `tests/integration/test_dns_route53_aws.py` |
| `prodbox test integration aws-eks` | `tests/integration/test_aws_eks.py` |
| `prodbox test integration env` | `tests/integration/test_cli_env.py` |
| `prodbox test integration gateway-daemon` | `tests/integration/test_gateway_daemon_k8s.py` |
| `prodbox test integration gateway-pods` | `tests/integration/test_gateway_k8s_pods.py` |
| `prodbox test integration gateway-partition` | `tests/integration/test_gateway_partition.py` |
| `prodbox test integration ha-rke2-aws` | `tests/integration/test_ha_rke2_aws.py` |
| `prodbox test integration lifecycle` | `tests/integration/test_prodbox_lifecycle.py` |
| `prodbox test integration pulumi` | `tests/integration/test_pulumi_real.py` |
| `prodbox test integration charts-storage` | `tests/integration/test_charts_storage.py` |
| `prodbox test integration charts-platform` | `tests/integration/test_charts_platform.py` |
| `prodbox test integration charts-vscode` | `tests/integration/test_charts_vscode.py` |
| `prodbox test integration public-dns` | `tests/integration/test_public_dns_delegation.py` |

Aggregate suite commands use a deterministic file order rather than raw
directory collection. `prodbox test all` runs `tests/unit` first and then the
canonical integration list. `prodbox test integration all` runs the external
public-host proof suites before cluster-backed suites that intentionally tear
down shared runtime, runs the AWS IAM lifecycle suite after Route 53-only AWS
validation but before Pulumi-backed stack validation because it needs AWS CLI +
Dhall tooling without the cluster runbook, runs `test_aws_eks.py` before
`test_pulumi_real.py` so the EKS and HA RKE2 paths are both proven against the
same restored backend posture, runs `test_charts_platform.py` before
`test_charts_storage.py` so the full-stack chart suite clears shared singleton
release names before the storage-only suite, keeps the lifecycle cleanup suite
last, fails in Phase 1.5 unless `prodbox host public-edge` reports
`CLASSIFICATION=ready-for-external-proof`, and restores the supported runtime
with `prodbox pulumi refresh`, `prodbox pulumi up --yes`,
`prodbox charts deploy gateway`, `prodbox charts deploy vscode`, a final
public-edge readiness check, `prodbox pulumi eks-destroy --yes`, and
`prodbox pulumi test-destroy --yes` before exit. Aggregate supported-runtime
repair also idempotently selects or creates the canonical Pulumi `home` stack
before any raw Pulumi AWS/provider repair runs, so no manual `pulumi stack
select` step is part of the supported flow.

`prodbox test integration charts-vscode` validates public HTTPS/TLS/auth-wall behavior only.
It does not run cluster prerequisite gates or the `rke2 install` runbook.

`prodbox test integration public-dns` validates authoritative public NS delegation for the
hosted zone that owns `VSCODE_FQDN`. It does not run cluster prerequisite gates or the
`rke2 install` runbook.

### `prodbox check-code`

| Command | Arguments | Options |
|---------|-----------|---------|
| `prodbox check-code` | none | none |

### `prodbox tla-check`

| Command | Arguments | Options |
|---------|-----------|---------|
| `prodbox tla-check` | none | none |

---

## 4. Test Command Contract

`prodbox test` exposes named suite commands only. The following are invalid by doctrine:

1. Raw pytest path forwarding such as `prodbox test tests/unit/test_env.py`
2. Marker forwarding such as `prodbox test -m "not integration"`
3. Arbitrary tool passthrough after `--`

For runbook and phase-order semantics of integration-selected suites, see [Unit Testing Policy](./unit_testing_policy.md#two-phase-test-command-doctrine).

---

## 5. Intent Ownership

This SSoT owns the explicit CLI surface doctrine.

- Owned statement: prodbox CLI commands accept only explicitly declared Click arguments and options; passthrough to downstream tools is prohibited.
- Linked dependents: `src/prodbox/cli/*.py`, `src/prodbox/lib/lint/click_passthrough_guard.py`, `tests/unit/test_cli_commands.py`.

---

## Cross-References

- [Development Plan](../../DEVELOPMENT_PLAN/README.md)
- [Documentation Standards](../documentation_standards.md)
- [Unit Testing Policy](./unit_testing_policy.md)
- [Code Quality Doctrine](./code_quality.md)
