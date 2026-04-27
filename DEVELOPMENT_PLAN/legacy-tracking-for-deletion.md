# Legacy Tracking

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md),
[development_plan_standards.md](development_plan_standards.md),
[system-components.md](system-components.md),
[phase-0-planning-documentation.md](phase-0-planning-documentation.md),
[phase-4-lifecycle-canonical-paths.md](phase-4-lifecycle-canonical-paths.md),
[phase-6-clean-room-handoff.md](phase-6-clean-room-handoff.md),
[phase-7-aws-iam-quota-automation.md](phase-7-aws-iam-quota-automation.md)

> **Purpose**: Record the completed Python-removal work and every surviving compatibility helper,
> duplicate surface, or tooling residue that is still slated for deletion during the Haskell
> rewrite.

> **Authoritative Reference**: [development_plan_standards.md](development_plan_standards.md#i-explicit-cleanup-and-removal-ledger)

## Ledger Status

The cleanup ledger is closed on the supported path. The Python-removal portion remains complete,
the later non-Python cleanup owned by Sprint `4.2` remains closed, and the completed items below
capture the removed compatibility surfaces and repository residue.

## Pending Removal

None.

## Completed

| Item | Removed In | Notes |
|------|------------|-------|
| Frontend Haskell-build container doctrine in `docker/prodbox.Dockerfile` and related tests/docs that mounted `haskell:9.6.7-slim` and created symlinked GHC tool shims | Sprint `1.1` implementation closure on April 26, 2026 | Replaced with a single-stage `ubuntu:24.04` frontend image that installs `ghcup` in-image, pins GHC `9.14.1`, preserves `/opt/build`, and removes the symlinked tool-shim path. |
| Gateway Haskell-build container doctrine in `docker/gateway.Dockerfile` and related tests/docs that mounted `haskell:9.6.7-slim` and created symlinked GHC tool shims | Sprint `2.1` implementation closure on April 26, 2026 | Replaced with a single-stage `ubuntu:24.04` gateway image that installs `ghcup` in-image, pins GHC `9.14.1`, preserves the official AWS CLI bundle keyed by `TARGETARCH`, and removes the symlinked tool-shim path. |
| Cluster-wide Zalando `postgres-operator` Helm release, `ghcr.io/zalando/postgres-operator`, `ghcr.io/zalando/spilo-17`, and `postgresqls.acid.zalan.do` chart/runtime assumptions | Sprint `3.3` implementation closure on April 26, 2026 | Replaced by the Percona operator surface in `src/Prodbox/CLI/Rke2.hs`, `src/Prodbox/ContainerImage.hs`, `src/Prodbox/PostgresPlatform.hs`, `charts/keycloak-postgres/`, and related tests. The live lifecycle now removes the incompatible legacy operator release and namespace before installing Percona. |
| Lifecycle-managed Haskell-build custom-image publication in `src/Prodbox/CLI/Rke2.hs` and related tests that injected the named BuildKit `haskell-toolchain` context pinned to `haskell:9.6.7-slim` | Sprint `4.1` implementation closure on April 26, 2026 | Replaced by direct `docker buildx build --platform linux/amd64,linux/arm64 --push` publication from the repo-owned Dockerfiles, with no mounted Haskell toolchain context and the explicit `ghc-9.14.1` repo upgrade in place. |
| Local-cluster supported ownership in `pulumi/home/Main.yaml` and the public `prodbox pulumi up|destroy|preview|refresh|stack-init` surface | Sprint `4.2` closure on April 23, 2026 | Pulumi is no longer the supported public operator surface for local-cluster platform ownership. The retained public Pulumi command family is limited to the AWS validation stacks, while the local lifecycle and chart runtime own the supported cluster path. The residual root `Pulumi.yaml` and `Pulumi.home.yaml` files were deleted in the Phase `6` cleanup closure on April 23, 2026. |
| Shared Bitnami `postgresql-ha` / `postgresql-repmgr` plus `pgpool` application-database doctrine | Sprint `3.3` closure on April 23, 2026 | Replaced by namespace-local Patroni-based Helm-managed PostgreSQL HA with exactly three replicas, synchronous replication, retained credentials, and no embedded chart-local PostgreSQL subcharts. The residual Bitnami Docker build artifacts were deleted in the Phase `6` cleanup closure on April 23, 2026. |
| Broader-than-target direct-public bootstrap image set in the lifecycle/runtime/docs | Sprint `4.1` closure on April 23, 2026 | The bootstrap exception now covers Harbor and Harbor's storage backend only before later Helm deployments switch to Harbor-backed image refs. |
| Harbor-first bootstrap ordering in `src/Prodbox/CLI/Rke2.hs` that mirrored required public images before the backend was healthy and deployed MinIO from Harbor-backed refs | Sprint 4.1 implementation closure on April 21, 2026 | Replaced by public-registry MinIO bootstrap, post-bootstrap Harbor populate, and a Harbor-backed MinIO steady-state reconcile |
| Python-era clean-room backlog through April 15, 2026 | Pre-rewrite baseline | Closed before the Haskell rewrite reopened this ledger on April 16, 2026 |
| `src/prodbox/**/*.py` Python implementation modules and `src/prodbox/py.typed` package marker | Sprint 4.3 | Deleted after Haskell parity reached for all supported surfaces |
| `tests/**/*.py` Python unit and integration harnesses | Sprint 4.3 | Replaced by Haskell test suites under `test/` |
| `typings/` Python type-stub inventory | Sprint 4.3 | Removed with Python runtime and mypy |
| `pyproject.toml`, `poetry.toml`, `.python-version` | Sprint 4.3 | Root Python packaging and Poetry ownership removed |
| Python-specific quality-tool ownership (`check_code.py`, `lint/`, ruff, mypy) | Sprint 4.3 | Replaced by Haskell `CheckCode.hs` |
| Python Pulumi runtimes and stack programs (`Pulumi.yaml` Python runtime, `src/prodbox/infra/`, `pulumi/aws-eks/__main__.py`, `pulumi/aws-test/__main__.py`) | Sprint 4.2 | Replaced with YAML Pulumi definitions for the retained AWS IaC surfaces: `pulumi/aws-eks/Main.yaml` and `pulumi/aws-test/Main.yaml` |
| Python CLI entrypoint and command-group ownership (`src/prodbox/cli/main.py`, `src/prodbox/cli/*.py`) | Sprint 4.3 | Haskell frontend owns the full command surface |
| Python settings, ADT, DAG, interpreter, and subprocess ownership | Sprint 4.3 | Replaced by Haskell modules under `src/Prodbox/` |
| Python local lifecycle and Harbor/local-registry helpers | Sprint 4.1 | `src/Prodbox/CLI/Rke2.hs` owns all lifecycle paths |
| Python gateway runtime and container entrypoint (`gateway_daemon.py`, `gateway.py`, Python Dockerfile entrypoint) | Sprint 2.1 | Replaced by the Haskell gateway runtime in `src/Prodbox/Gateway.hs`, `src/Prodbox/Gateway/Daemon.hs`, `src/Prodbox/Gateway/Types.hs`, and the canonical single-stage `docker/gateway.Dockerfile` build |
| Python DNS inspection command (`dns.py`) | Sprint 2.1 | `src/Prodbox/Dns.hs` owns the surface |
| Python TLA+ CLI wrapper and proof-check helper (`tla.py`, `tla_check.py`) | Sprint 2.2 | `src/Prodbox/Tla.hs` owns the surface |
| Python chart orchestration and retained-state helpers (`charts.py`, `chart_platform.py`, Python chart test suites) | Sprint 3.1 | `src/Prodbox/CLI/Charts.hs`, `src/Prodbox/Lib/ChartPlatform.hs`, and `src/Prodbox/Lib/Storage.hs` own the runtime |
| Python public-edge diagnostic helpers (`host.py`, public-edge report logic in `dag_builders.py`) | Sprint 5.1 | `src/Prodbox/Host.hs` owns the surface |
| Python interactive onboarding helper (`config_cmd.py`) | Sprint 7.1 | `src/Prodbox/Aws.hs` owns `config setup` |
| Python standalone IAM and quota commands (`aws_cmd.py`) | Sprint 7.2 | `src/Prodbox/Aws.hs` owns `aws setup|teardown|check-quotas|request-quotas` |
| Python elevated-credential IAM helper (`aws_admin.py`) | Sprint 7.3 | Haskell `aws_admin` harness owns real IAM lifecycle proof |
| Public `aws_admin.*` fallback in `src/Prodbox/Aws.hs` (`configuredAdminCredentials`, `resolveAdminCredentials`, `resolveAdminCredentialsWithRegionChoice`, and the non-interactive fallback guidance) | Sprint `7.1` / Sprint `7.2` | Removed so public `prodbox config setup` and public `prodbox aws ...` now prompt for one temporary elevated credential set instead of reading stored `aws_admin.*`. |
| Non-test `aws_admin.*` recovery path in `src/Prodbox/SupportedRuntime.hs` | Sprint `7.3` | Removed so stored `aws_admin.*` is no longer consumed outside the native IAM validation harness. |
| Python bridge modules (`Backend/Python.hs`, `PythonEnv.hs`) | Sprint 4.3 | `Main.hs` no longer imports `Backend.Python` |
| Residual Python-era command delegation and supported-runtime field naming (`DelegateToPython`, `supportedRuntimePythonPath`) | Sprint 6.2 audit closure on April 19, 2026 | The frontend now dispatches directly to native Haskell commands, and supported-runtime helpers no longer expose Python-named context fields |
| Phase-owned engineering docs presenting Python as supported architecture | Sprint 6.2 | Doctrine aligned with the Haskell-only architecture |
| Surviving Python-era architecture references in supported-path docs | Sprint 6.2 | Final cleanup sweep completed |
| `prodbox-config.json` compatibility path and public `prodbox config compile` surface | Sprint 1.2 runtime closure on April 18, 2026 | `src/Prodbox/Settings.hs`, `src/Prodbox/CLI/Parser.hs`, `src/Prodbox/Native.hs`, `src/Prodbox/Repo.hs`, `src/Prodbox/Aws.hs`, `test/unit/Main.hs`, `test/integration/cli/Main.hs`, and `test/integration/env/Main.hs` now close on direct `Dhall -> Haskell types`; no supported command materializes the JSON artifact |
| Stale mixed-baseline or removed-tooling wording in root guidance and governed docs such as `README.md`, `AGENTS.md`, `CLAUDE.md`, `documents/engineering/README.md`, `documents/engineering/cli_command_surface.md`, `documents/engineering/code_quality.md`, `documents/engineering/dependency_management.md`, and `documents/engineering/unit_testing_policy.md` | Sprint 1.2 doc-harmony closure on April 18, 2026 | Root guidance and the governed docs listed by Sprint `1.2` now describe the Haskell-only repository, direct-Dhall config contract, and native validation harness |
| Repository-root `Dockerfile` and root-level references that treated it as canonical | Sprint 1.1 closure on April 18, 2026 | The canonical frontend image now lives at `docker/prodbox.Dockerfile`, and supported references point to `docker/` only |
| Multi-stage frontend image build in the former root `Dockerfile` (`haskell:9.6.7 -> debian:bookworm-slim`) | Sprint 1.1 closure on April 18, 2026 | Replaced with a single-stage `ubuntu:24.04` frontend image while preserving `/opt/build` |
| Multi-stage gateway image build in `docker/gateway.Dockerfile` (`haskell:9.6.7 -> debian:bookworm-slim`) | Sprint 2.1 closure on April 18, 2026 | Replaced with a single-stage `ubuntu:24.04` gateway image |
| `vscode-nginx` delivery gap for Harbor-only dual-arch image publication | Sprint 3.2 closure on April 18, 2026 | `docker/nginx-oidc.Dockerfile` remains the permitted Alpine-based exception, but the supported stack now publishes it to Harbor and references Harbor only |
| Supported doctrine that framed Harbor as a local mirror or allowed arbitrary non-Harbor workload pulls | Sprint 4.1 closure on April 18, 2026 | Supported charts and Pulumi home-stack workloads reference Harbor-backed images in steady state; the only supported public-image exception is the narrow Harbor/bootstrap path owned by Sprint `4.1` |
| Arch-implicit container population doctrine without explicit `amd64` plus `arm64` and mixed-arch closure | Sprint 4.1 closure on April 18, 2026 | The lifecycle now reconciles required public images and custom images for both `amd64` and `arm64` irrespective of local host architecture |

## Related Documents

- [phase-4-lifecycle-canonical-paths.md](phase-4-lifecycle-canonical-paths.md)
- [phase-6-clean-room-handoff.md](phase-6-clean-room-handoff.md)
- [phase-7-aws-iam-quota-automation.md](phase-7-aws-iam-quota-automation.md)
