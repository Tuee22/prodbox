# CLI Command Surface

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: README.md, AGENTS.md, CLAUDE.md, DEVELOPMENT_PLAN/README.md, DEVELOPMENT_PLAN/system-components.md, documents/engineering/README.md, documents/engineering/acme_provider_guide.md, documents/engineering/aws_account_setup_guide.md, documents/engineering/aws_admin_credentials.md, documents/engineering/aws_integration_environment_doctrine.md, documents/engineering/dependency_management.md, documents/engineering/unit_testing_policy.md, documents/engineering/helm_chart_platform_doctrine.md

> **Purpose**: Define the explicit, no-passthrough command surface for `prodbox`.

## 1. Command Surface Statement

`prodbox` CLI commands accept only explicitly declared arguments and options at the parser
boundary; passthrough to downstream tools is prohibited.

The CLI surface is intentionally closed:

1. Unknown extra arguments fail at the CLI parser boundary.
2. Invoking a command group without a subcommand displays help instead of running an implicit
   default.
3. Every supported test subset is exposed as a named command, not as a raw file selector.

Current implementation:

- `app/prodbox/Main.hs`, `src/Prodbox/CLI/Command.hs`, `src/Prodbox/CLI/Parser.hs`, and
  `src/Prodbox/Native.hs` own the public parser, request ADT, and command dispatch.
- The frontend request ADT routes only to native Haskell commands; no Python delegation branch
  survives in the parser or entrypoint.
- Runtime ownership lives in Haskell modules under `src/Prodbox/`.
- Named test validations live in `src/Prodbox/TestPlan.hs`, `src/Prodbox/TestRunner.hs`, and
  `src/Prodbox/TestValidation.hs`.

This document defines the supported command contract only. Sequencing, completion status, and
cleanup ownership are owned by [DEVELOPMENT_PLAN/README.md](../../DEVELOPMENT_PLAN/README.md).

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
| `host` | Group | Host prerequisite checks and public-edge diagnostics |
| `rke2` | Group | Local cluster lifecycle |
| `pulumi` | Group | AWS validation stack lifecycle |
| `dns` | Group | Route 53 inspection |
| `k8s` | Group | Kubernetes health and log utilities |
| `gateway` | Group | Gateway daemon operations |
| `charts` | Group | Bespoke Helm chart lifecycle |
| `test` | Group | Explicit named test suites |
| `check-code` | Command | Formatter, lint, warning-clean build, and operator-binary sync gate |
| `tla-check` | Command | TLA+ model checking via Docker |

## 3. Command Matrix

### `prodbox config`

| Command | Arguments | Options |
|---------|-----------|---------|
| `prodbox config setup` | none | none |
| `prodbox config show` | none | `--show-secrets` |
| `prodbox config validate` | none | none |

`src/Prodbox/Aws.hs` owns `config setup`. `src/Prodbox/Settings.hs` owns `config show` and
`config validate`. `prodbox config compile` is not part of the supported command surface. The
supported public `config setup` path prompts for one temporary elevated AWS credential set when
needed; stored `aws_admin_for_test_simulation.*` remains reserved for test-suite simulation of
that prompt input, with the native IAM test harness as the only supported runtime consumer.

### `prodbox aws`

| Command | Arguments | Options |
|---------|-----------|---------|
| `prodbox aws policy` | none | `--tier` |
| `prodbox aws setup` | none | `--tier` |
| `prodbox aws teardown` | none | none |
| `prodbox aws check-quotas` | none | none |
| `prodbox aws request-quotas` | none | `--tier` |

`src/Prodbox/Aws.hs` owns the full public `prodbox aws ...` surface. The supported public contract
is prompt-driven for temporary elevated AWS credentials; stored
`aws_admin_for_test_simulation.*` is not part of the intended public operator flow.

### `prodbox host`

| Command | Arguments | Options |
|---------|-----------|---------|
| `prodbox host ensure-tools` | none | none |
| `prodbox host check-ports` | none | none |
| `prodbox host info` | none | none |
| `prodbox host firewall` | none | none |
| `prodbox host public-edge` | none | none |

`src/Prodbox/Host.hs` owns the full public `prodbox host ...` surface.

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

`src/Prodbox/CLI/Rke2.hs` owns the full public `prodbox rke2 ...` surface.

`prodbox rke2 delete --yes` is summary-oriented on success: it reports AWS validation destroy
disposition, local substrate cleanup, managed kubeconfig handling, and preserved host roots
without streaming raw uninstall-script trace output.

### `prodbox pulumi`

| Command | Arguments | Options |
|---------|-----------|---------|
| `prodbox pulumi eks-resources` | none | none |
| `prodbox pulumi eks-destroy` | none | `--yes`, `-y` |
| `prodbox pulumi test-resources` | none | none |
| `prodbox pulumi test-destroy` | none | `--yes`, `-y` |

`src/Prodbox/CLI/Pulumi.hs` owns the full public `prodbox pulumi ...` surface.

`prodbox pulumi eks-destroy --yes` and `prodbox pulumi test-destroy --yes` report one-line stack
destroy disposition instead of replaying Pulumi login chatter on successful cleanup.

No supported local-cluster platform or application deployment depends on a root Pulumi project.

### `prodbox dns`

| Command | Arguments | Options |
|---------|-----------|---------|
| `prodbox dns check` | none | none |

`src/Prodbox/Dns.hs` owns the public DNS inspection surface.

### `prodbox k8s`

| Command | Arguments | Options |
|---------|-----------|---------|
| `prodbox k8s health` | none | none |
| `prodbox k8s wait` | none | `--timeout`, `-t`, `--namespace`, `-n` |
| `prodbox k8s logs` | none | `--namespace`, `-n`, `--tail` |

`src/Prodbox/K8s.hs` owns the public Kubernetes helper surface.

### `prodbox gateway`

| Command | Arguments | Options |
|---------|-----------|---------|
| `prodbox gateway start` | `CONFIG_PATH` | none |
| `prodbox gateway status` | `CONFIG_PATH` | none |
| `prodbox gateway config-gen` | `OUTPUT_PATH` | `--node-id` |

`src/Prodbox/Gateway.hs` owns the public gateway surface and `src/Prodbox/Gateway/Daemon.hs`
owns the daemon runtime.

### `prodbox charts`

| Command | Arguments | Options |
|---------|-----------|---------|
| `prodbox charts list` | none | none |
| `prodbox charts status` | `CHART` | none |
| `prodbox charts deploy` | `CHART` | none |
| `prodbox charts delete` | `CHART` | `--yes`, `-y` |

`src/Prodbox/CLI/Charts.hs`, `src/Prodbox/Lib/ChartPlatform.hs`,
`src/Prodbox/Lib/Storage.hs`, and `src/Prodbox/PostgresPlatform.hs` own the public chart surface
and its canonical external Patroni naming contract.

The supported chart doctrine does not permit embedded chart-local PostgreSQL subcharts.
`keycloak-postgres` is an internal namespace-local Patroni dependency release, and chart deploy
fails fast until `prodbox rke2 install` has reconciled the cluster-wide `postgres-operator`
platform.

### `prodbox test`

`prodbox test` and `prodbox test integration` are help groups only. They do not run an implicit
default suite.

Shared executable-suite options:

| Option | Meaning |
|--------|---------|
| `--coverage` | Enable coverage mode for the selected scope |
| `--cov-fail-under INTEGER` | Require a minimum coverage percentage; valid only with `--coverage` |

Named suite commands:

| Command | Scope |
|---------|-------|
| `prodbox test all` | Aggregate Haskell unit and integration surface |
| `prodbox test unit` | `test:prodbox-unit` |
| `prodbox test integration all` | Aggregate integration surface |
| `prodbox test integration cli` | `test:prodbox-integration-cli` |
| `prodbox test integration env` | `test:prodbox-integration-env` |
| `prodbox test integration aws-iam` | Native IAM lifecycle validation |
| `prodbox test integration dns-aws` | Native Route 53 lifecycle validation |
| `prodbox test integration aws-eks` | Native EKS validation |
| `prodbox test integration gateway-daemon` | Native gateway daemon validation |
| `prodbox test integration gateway-pods` | Native gateway pod validation |
| `prodbox test integration gateway-partition` | Native gateway partition validation |
| `prodbox test integration ha-rke2-aws` | Native HA RKE2 AWS validation |
| `prodbox test integration lifecycle` | Native destructive lifecycle validation |
| `prodbox test integration pulumi` | Native Pulumi validation |
| `prodbox test integration charts-storage` | Native chart storage validation |
| `prodbox test integration charts-platform` | Native chart platform validation |
| `prodbox test integration charts-vscode` | Native external `vscode` validation |
| `prodbox test integration public-dns` | Native public DNS delegation validation |

`src/Prodbox/TestRunner.hs` owns the public `prodbox test` entrypoint. It:

- runs Haskell suites through `cabal test`
- enforces prerequisite gates and runbook steps
- applies the canonical aggregate ordering
- keeps stored `aws_admin_for_test_simulation.*` confined to test-suite simulation and the native
  `aws-iam` harness rather than the public command surface
- performs supported-runtime bootstrap and postflight when required
- waits for `prodbox host public-edge` to report `CLASSIFICATION=ready-for-external-proof` before
  external `charts-vscode` proof continues on the supported-runtime path
- dispatches named real-world validations through `src/Prodbox/TestValidation.hs`

### `prodbox check-code`

| Command | Arguments | Options |
|---------|-----------|---------|
| `prodbox check-code` | none | none |

`src/Prodbox/CheckCode.hs` owns the public `check-code` entrypoint.

The supported command runs Fourmolu, HLint, warning-clean `cabal build`, and the final operator
binary sync. Detailed Haskell quality doctrine is defined in
[Haskell Code Guide](./haskell_code_guide.md).

### `prodbox tla-check`

| Command | Arguments | Options |
|---------|-----------|---------|
| `prodbox tla-check` | none | none |

`src/Prodbox/Tla.hs` owns the public TLA+ validation surface.

## Cross-References

- [Development Plan](../../DEVELOPMENT_PLAN/README.md)
- [Unit Testing Policy](./unit_testing_policy.md)
- [Code Quality Doctrine](./code_quality.md)
- [Haskell Code Guide](./haskell_code_guide.md)
