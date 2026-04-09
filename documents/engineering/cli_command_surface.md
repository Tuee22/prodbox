# CLI Command Surface

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: README.md, AGENTS.md, CLAUDE.md, DEVELOPMENT_PLAN/README.md, documents/engineering/README.md, documents/engineering/aws_integration_environment_doctrine.md, documents/engineering/dependency_management.md, documents/engineering/unit_testing_policy.md, documents/engineering/helm_chart_platform_doctrine.md

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
| `config` | Group | Dhall configuration management |
| `host` | Group | Host prerequisite checks |
| `rke2` | Group | Local cluster lifecycle |
| `pulumi` | Group | Infrastructure deployment |
| `dns` | Group | Route 53 inspection |
| `k8s` | Group | Kubernetes health and log utilities |
| `gateway` | Group | Gateway daemon operations |
| `charts` | Group | Bespoke Helm chart lifecycle |
| `aws` | Group | AWS fixture management |
| `test` | Group | Explicit named test suites |
| `check-code` | Command | Policy guards + `ruff` + `mypy` |
| `tla-check` | Command | TLA+ model checking via Docker |

---

## 3. Command Matrix

### `prodbox config`

| Command | Arguments | Options |
|---------|-----------|---------|
| `prodbox config init` | none | none |
| `prodbox config compile` | none | none |
| `prodbox config show` | none | none |
| `prodbox config validate` | none | none |

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
| `prodbox rke2 ensure` | none | none |
| `prodbox rke2 cleanup` | none | `--yes` |
| `prodbox rke2 logs` | none | `--lines`, `-n` |

### `prodbox pulumi`

| Command | Arguments | Options |
|---------|-----------|---------|
| `prodbox pulumi up` | none | `--yes`, `-y` |
| `prodbox pulumi destroy` | none | `--yes`, `-y` |
| `prodbox pulumi preview` | none | none |
| `prodbox pulumi refresh` | none | none |
| `prodbox pulumi stack-init` | `STACK` | none |

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
| `prodbox gateway install-service` | `CONFIG_PATH` | `--output-path` |

### `prodbox charts`

| Command | Arguments | Options |
|---------|-----------|---------|
| `prodbox charts list` | none | none |
| `prodbox charts status` | `CHART` | none |
| `prodbox charts deploy` | `CHART` | none |
| `prodbox charts delete` | `CHART` | `--yes`, `-y` |

### `prodbox aws`

| Command | Arguments | Options |
|---------|-----------|---------|
| `prodbox aws sweep-fixtures` | none | none |

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
| `prodbox test integration aws-foundation` | `tests/integration/test_aws_foundation_real.py` |
| `prodbox test integration aws-eks` | `tests/integration/test_aws_eks_real.py` |
| `prodbox test integration cli` | `tests/integration/test_cli_commands.py` |
| `prodbox test integration dns-aws` | `tests/integration/test_dns_route53_aws.py` |
| `prodbox test integration env` | `tests/integration/test_cli_env.py` |
| `prodbox test integration gateway-daemon` | `tests/integration/test_gateway_daemon_k8s.py` |
| `prodbox test integration gateway-pods` | `tests/integration/test_gateway_k8s_pods.py` |
| `prodbox test integration lifecycle` | `tests/integration/test_prodbox_lifecycle.py` |
| `prodbox test integration pulumi` | `tests/integration/test_pulumi_real.py` |
| `prodbox test integration charts-storage` | `tests/integration/test_charts_storage.py` |
| `prodbox test integration charts-platform` | `tests/integration/test_charts_platform.py` |
| `prodbox test integration charts-vscode` | `tests/integration/test_charts_vscode.py` |
| `prodbox test integration public-dns` | `tests/integration/test_public_dns_delegation.py` |

`prodbox test integration charts-vscode` validates public HTTPS/TLS/auth-wall behavior only.
It does not run cluster prerequisite gates or the `rke2 ensure` runbook.

`prodbox test integration public-dns` validates authoritative public NS delegation for the
hosted zone that owns `VSCODE_FQDN`. It does not run cluster prerequisite gates or the
`rke2 ensure` runbook.

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
