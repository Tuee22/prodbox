# Legacy Tracking

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [development_plan_standards.md](development_plan_standards.md), [phase-4-lifecycle-canonical-paths.md](phase-4-lifecycle-canonical-paths.md), [phase-6-clean-room-handoff.md](phase-6-clean-room-handoff.md), [phase-7-aws-iam-quota-automation.md](phase-7-aws-iam-quota-automation.md)

> **Purpose**: Record the completed Python-removal work, including every compatibility helper,
> duplicate surface, and tooling residue that was deleted during the Haskell rewrite.

> **Authoritative Reference**: [development_plan_standards.md](development_plan_standards.md#i-explicit-cleanup-and-removal-ledger)

## Ledger Status

As of April 17, 2026, all Python-removal items have been completed. The Python toolchain has been
completely removed from the repository: all Python source (`src/prodbox/`, `tests/`, `typings/`),
Python packaging (`pyproject.toml`, `poetry.toml`, `.python-version`), Python bridge modules
(`Backend/Python.hs`, `PythonEnv.hs`), and Python Pulumi programs have been deleted. All Pulumi
programs are now YAML-based. The `Pending Removal` section is empty.

## Pending Removal

None. All Python-removal items have been completed.

## Completed

| Item | Removed In | Notes |
|------|------------|-------|
| Python-era clean-room backlog through April 15, 2026 | Pre-rewrite baseline | Closed before the Haskell rewrite reopened this ledger on April 16, 2026 |
| `src/prodbox/**/*.py` Python implementation modules and `src/prodbox/py.typed` package marker | Sprint 4.3 | Deleted after Haskell parity reached for all supported surfaces |
| `tests/**/*.py` Python unit and integration harnesses | Sprint 4.3 | Replaced by Haskell test suites under `test/` |
| `typings/` Python type-stub inventory | Sprint 4.3 | Removed with Python runtime and mypy |
| `pyproject.toml`, `poetry.toml`, `.python-version` | Sprint 4.3 | Root Python packaging and Poetry ownership removed |
| Python-specific quality-tool ownership (`check_code.py`, `lint/`, ruff, mypy) | Sprint 4.3 | `CheckCode.hs` now runs `cabal build --builddir=.build all` |
| Python Pulumi runtimes and stack programs (`Pulumi.yaml` Python runtime, `src/prodbox/infra/`, `pulumi/aws-eks/__main__.py`, `pulumi/aws-test/__main__.py`) | Sprint 4.2 | Replaced with YAML Pulumi definitions: `pulumi/home/Main.yaml`, `pulumi/aws-eks/Main.yaml`, `pulumi/aws-test/Main.yaml` |
| Python CLI entrypoint and command-group ownership (`src/prodbox/cli/main.py`, `src/prodbox/cli/*.py`) | Sprint 4.3 | Haskell frontend owns the full command surface |
| Python settings, ADT, DAG, interpreter, and subprocess ownership | Sprint 4.3 | Replaced by Haskell modules under `src/Prodbox/` |
| Python local lifecycle and Harbor/local-registry helpers | Sprint 4.1 | `src/Prodbox/CLI/Rke2.hs` owns all lifecycle paths |
| Python gateway runtime and container entrypoint (`gateway_daemon.py`, `gateway.py`, Python Dockerfile entrypoint) | Sprint 2.1 | `docker/gateway.Dockerfile` now builds Haskell binary with multi-stage build |
| Python DNS inspection command (`dns.py`) | Sprint 2.1 | `src/Prodbox/Dns.hs` owns the surface |
| Python TLA+ CLI wrapper and proof-check helper (`tla.py`, `tla_check.py`) | Sprint 2.2 | `src/Prodbox/Tla.hs` owns the surface |
| Python chart orchestration and retained-state helpers (`charts.py`, `chart_platform.py`, Python chart test suites) | Sprint 3.1 | `src/Prodbox/CLI/Charts.hs`, `src/Prodbox/Lib/ChartPlatform.hs`, `src/Prodbox/Lib/Storage.hs` own the runtime |
| Python public-edge diagnostic helpers (`host.py`, public-edge report logic in `dag_builders.py`) | Sprint 5.1 | `src/Prodbox/Host.hs` owns the surface |
| Python interactive onboarding helper (`config_cmd.py`) | Sprint 7.1 | `src/Prodbox/Aws.hs` owns `config setup` |
| Python standalone IAM and quota commands (`aws_cmd.py`) | Sprint 7.2 | `src/Prodbox/Aws.hs` owns `aws setup|teardown|check-quotas|request-quotas` |
| Python elevated-credential IAM helper (`aws_admin.py`) | Sprint 7.3 | Haskell `aws_admin` harness owns real IAM lifecycle proof |
| Python bridge modules (`Backend/Python.hs`, `PythonEnv.hs`) | Sprint 4.3 | `Main.hs` no longer imports `Backend.Python` |
| Phase-owned engineering docs presenting Python as supported architecture | Sprint 6.2 | Doctrine aligned with Haskell-only architecture |
| Surviving Python-era architecture references in supported-path docs | Sprint 6.2 | Final cleanup sweep completed |
| Root guidance docs `README.md`, `AGENTS.md`, and `CLAUDE.md`, plus the engineering documentation index `documents/engineering/README.md`, presenting Python as the final handoff architecture | Documentation-harmony cleanup on April 16, 2026 | Rewritten to point at `DEVELOPMENT_PLAN/README.md` as the live tracker and to describe Python as the current baseline rather than the supported end state |
| Retained Python supported-runtime helper calls from the Haskell `test` runner into `src/prodbox/cli/test_cmd.py` and `src/prodbox/lib/aws_admin.py` | Sprint 1.2 runtime-repair cleanup on April 17, 2026 | Replaced by native Haskell helper ownership in `src/Prodbox/SupportedRuntime.hs`; `src/prodbox/cli/test_cmd.py` now remains only as the legacy direct-backend `test` implementation under `PRODBOX_PYTHON_BACKEND=1` |
| Retained Python env integration suite `tests/integration/test_cli_env.py` | Sprint 1.2 validation-handoff cleanup on April 17, 2026 | Replaced by native Haskell config/env proof in `test/integration/env/Main.hs`; `prodbox test integration env` now runs entirely on the Haskell suite |
| Public `prodbox rke2` command ownership on the Haskell frontend | Sprint 1.3 command-surface repair on April 17, 2026 | `src/Prodbox/CLI/Rke2.hs` now owns the public entry surface; retained `src/prodbox/cli/rke2.py` and deeper lifecycle runtime still survive until Sprint `1.3` closes |
| Public `prodbox pulumi` command ownership on the Haskell frontend | Sprint 1.3 command-surface repair on April 17, 2026 | `src/Prodbox/CLI/Pulumi.hs` now owns the public entry surface and routes `eks-resources|eks-destroy|test-resources|test-destroy` through native Haskell modules `src/Prodbox/Infra/AwsEksTestStack.hs` and `src/Prodbox/Infra/AwsTestStack.hs`; retained Python Pulumi stack programs still survive until Sprint `4.2` closes |
| Native `prodbox rke2 install|delete|status|start|stop|restart|logs` runtime ownership on the Haskell frontend | Sprint 1.3 runtime-slice repair on April 17, 2026 | `src/Prodbox/CLI/Rke2.hs` now executes the full supported local lifecycle without the Python backend, including Harbor/local-registry bootstrap, MinIO bootstrap, image reconcile, and annotation repair; `rke2 delete --yes` now uses native Haskell Pulumi destroy instead of Python backend delegation |
| Native `prodbox pulumi up|preview|destroy|refresh|stack-init|eks-resources|eks-destroy|test-resources|test-destroy` runtime ownership on the Haskell frontend | Sprint 1.3 runtime-slice repair on April 17, 2026 | `src/Prodbox/CLI/Pulumi.hs` now performs Pulumi login, stack selection, repo-local backend setup, direct subprocess orchestration, and post-apply identity or annotation reconciliation for all Pulumi commands; `eks-resources|eks-destroy|test-resources|test-destroy` route through native Haskell modules `src/Prodbox/Infra/AwsEksTestStack.hs`, `src/Prodbox/Infra/AwsTestStack.hs`, and `src/Prodbox/Infra/MinioBackend.hs`; retained Python stack programs still survive until Sprint `4.2` closes |
| Public `prodbox dns check` command ownership on the Haskell frontend | Sprint 2.1 command-surface repair on April 17, 2026 | `src/Prodbox/Dns.hs` now owns the public surface; retained `src/prodbox/cli/dns.py` survives only as the legacy direct-backend wrapper under `PRODBOX_PYTHON_BACKEND=1` |
| Public `prodbox gateway start` entry-surface and daemon runtime ownership on the Haskell frontend | Sprint 2.1 native daemon runtime on April 17, 2026 | `src/Prodbox/Gateway.hs` now uses native `Daemon.runGatewayDaemon` from `src/Prodbox/Gateway/Daemon.hs` and `src/Prodbox/Gateway/Types.hs` instead of delegating to the Python backend; the retained Python daemon in `src/prodbox/gateway_daemon.py` and `src/prodbox/cli/gateway.py` now exists only as cleanup residue |
| Public `prodbox gateway status|config-gen` command ownership on the Haskell frontend | Sprint 2.1 command-surface repair on April 17, 2026 | `src/Prodbox/Gateway.hs` now owns the public surfaces; retained `src/prodbox/cli/gateway.py`, `src/prodbox/gateway_daemon.py`, and `docker/gateway.Dockerfile` still survive for `gateway start`, daemon runtime, and container packaging until Sprint `2.1` closes |
| Public `prodbox tla-check` command ownership on the Haskell frontend | Sprint 2.2 command-surface repair on April 17, 2026 | `src/Prodbox/Tla.hs` now owns the public surface; retained `src/prodbox/cli/tla.py` and `src/prodbox/tla_check.py` survive only as the legacy direct-backend wrappers under `PRODBOX_PYTHON_BACKEND=1` |
| Public `prodbox charts` runtime ownership on the Haskell frontend | Sprint 3.1 runtime port on April 17, 2026 | `src/Prodbox/CLI/Charts.hs`, `src/Prodbox/Lib/ChartPlatform.hs`, and `src/Prodbox/Lib/Storage.hs` now own the default public `prodbox charts list|status|deploy|delete` path; retained `src/prodbox/cli/charts.py`, `src/prodbox/lib/chart_platform.py`, and Python chart integration suites still survive until Sprint `3.1` closes |
| Public `prodbox host public-edge` command ownership on the Haskell frontend | Sprint 5.1 command-surface repair on April 17, 2026 | `src/Prodbox/Host.hs` now owns the public surface; retained `src/prodbox/cli/host.py` and duplicate public-edge report logic in `src/prodbox/cli/dag_builders.py` survive only as the legacy direct-backend path under `PRODBOX_PYTHON_BACKEND=1` |

## Related Documents

- [phase-4-lifecycle-canonical-paths.md](phase-4-lifecycle-canonical-paths.md)
- [phase-6-clean-room-handoff.md](phase-6-clean-room-handoff.md)
- [phase-7-aws-iam-quota-automation.md](phase-7-aws-iam-quota-automation.md)
