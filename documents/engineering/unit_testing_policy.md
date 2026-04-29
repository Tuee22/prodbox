# Unit Testing Policy

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: README.md, AGENTS.md, CLAUDE.md, DEVELOPMENT_PLAN/README.md, documents/engineering/README.md, documents/engineering/aws_integration_environment_doctrine.md, documents/engineering/aws_test_environment.md, documents/engineering/cli_command_surface.md, documents/engineering/code_quality.md, documents/engineering/distributed_gateway_architecture.md, documents/engineering/envoy_gateway_edge_doctrine.md, documents/engineering/helm_chart_platform_doctrine.md, documents/engineering/integration_fixture_doctrine.md, documents/engineering/prerequisite_dag_system.md, documents/engineering/streaming_doctrine.md

> **Purpose**: Define the interpreter-only mocking doctrine and public test-runner contract for
> `prodbox`.

## 0. Canonical Skip Policy Statement

Skip/xfail is prohibited by default; missing prerequisites must fail fast with actionable errors.

The public `prodbox test` surface uses a two-stage model:

- Phase `1/2`: prerequisite validation
- optional Phase `1.5/2` or `1.6/2`: runbook and supported-runtime preparation
- Phase `2/2`: Haskell test suites and named validation payloads

This document defines testing doctrine only. Sequencing, completion status, and cleanup ownership
are owned by [DEVELOPMENT_PLAN/README.md](../../DEVELOPMENT_PLAN/README.md).

## 1. The Interpreter-Only Mocking Doctrine

### Core Rule

**Pure code never touches mocks. All mocking happens at the subprocess or interpreter boundary.**

In the current repository:

- pure helpers, DAG logic, renderers, and validation helpers should be testable without mocks
- subprocess fakes belong in built-frontend integration suites such as `test/integration/cli/Main.hs`
- prerequisite and runtime orchestration belong in native Haskell modules under `src/Prodbox/`

## 2. Unit vs Integration Tests

| Aspect | Unit Test | Integration Test |
|--------|-----------|------------------|
| External systems | Faked or avoided | Real or built-frontend |
| Speed | Fast | Slower |
| Dependencies | Minimal | Tooling, cluster, AWS, or DNS as required |
| Where mocks live | Boundary only | N/A or fake-tool harness |

### Test Categories

| Category | What Gets Tested | Location |
|----------|------------------|----------|
| Pure helper tests | Parsing, rendering, ADTs, DAG logic, validation helpers | `test/unit/Main.hs` |
| Built-frontend integration tests | CLI routing and subprocess behavior against fake tools | `test/integration/cli/Main.hs` |
| Built-frontend config tests | Direct-Dhall config masking and validation behavior | `test/integration/env/Main.hs` |
| Native real-world validations | AWS, DNS, gateway, chart, lifecycle, and public-edge proofs | `src/Prodbox/TestValidation.hs` via `prodbox test integration ...` |

### Integration Execution Policy (Fail-Fast)

- Integration selections must fail fast when prerequisites are missing.
- Platform and environment gating belongs in prerequisite validation, not in skips.
- Use `./.build/prodbox test unit` when integration prerequisites are unavailable.

### Two-Phase Test Command Doctrine

Integration-selected `prodbox test` commands execute in two phases:

1. **Phase 1 - prerequisite gate**: validate integration prerequisites before deeper work starts.
   Suites may split this gate into an initial fail-fast prerequisite pass plus a deferred
   cluster-backed backend proof when the deferred proof depends on a visible runbook-created local
   runtime such as the RKE2-backed MinIO Pulumi backend.
2. **Phase 1.5 - integration runbook gate**: cluster-backed suites may enforce
   `prodbox rke2 install`.
3. **Phase 1.6 - supported runtime bootstrap**: aggregate or destructive flows may repair the
   supported runtime before validation.
4. **Phase 2 - test execution**: run Haskell suites and named validation payloads only after the
   earlier phases succeed.

When Phase `1.6/2` restores a cluster-backed supported runtime for external proof, it may wait for
`prodbox host public-edge` to report `CLASSIFICATION=ready-for-external-proof` before the payload
starts. The target doctrine for that readiness is Gateway API plus Envoy Gateway state; the
current Traefik and `Ingress` implementation remains migration residue owned by the reopened plan
phases.

When a Phase `1/2` prerequisite owns a deterministic local backend proof, it may perform a
visible, bounded repair of repository-managed state before re-running the same readiness check. The
canonical current example is the MinIO-backed Pulumi prerequisite recreating a deleted retained
export host path and restarting `deployment/minio` before retrying backend login.

If Phase 1 fails, Phase 2 is not started. This is an all-or-nothing gate, not a skip.

### Phase Banner Rendering Contract

`prodbox test` phase banners are operator-facing progress records. Their visible order is part of
the command contract.

1. Visible banner order is exact: `Phase 1/2`, optional `Phase 1.5/2`, optional `Phase 1.6/2`,
   then `Phase 2/2`.
2. Each phase banner is emitted as its own stdout line.
3. Deferred Phase `1/2` checks may run after Phase `1.5/2` or `1.6/2`, but `Phase 2/2` is
   emitted only after every Phase `1` gate succeeds.
4. Post-test repair banners are also part of the visible contract when aggregate runtime repair is
   required.

### Command-Scope Prerequisite Aggregation

`prodbox test` applies prerequisite gates at command scope:

1. The selected suite determines the root prerequisite set.
2. Unit-only scope bypasses integration gates.
3. Cluster-backed suites may keep initial host, tool, config, and AWS checks in the front half of
   Phase `1/2`, then defer cluster-backed backend proofs such as `pulumi_logged_in` until after
   the visible runbook has created or repaired the local runtime they depend on.
4. `charts-vscode` is a supported-runtime cluster-backed suite and therefore enforces the cluster
   runbook plus supported-runtime bootstrap before its external proof, and that bootstrap waits
   for `prodbox host public-edge` readiness rather than using a one-shot assertion. Public-host
   suites such as `public-dns` may avoid the cluster runbook only when their test plan does not
   require it.
5. Aggregate suites use the canonical validation ordering defined in `src/Prodbox/TestPlan.hs`.

If future workloads expose WebSockets behind the supported public edge, named validations must
prove connection-time auth, reconnect handling, and any required shared-state backend assumptions.

### Session Fixtures vs Test DAG (SSoT)

Session-style hidden setup is not the supported orchestration model for command-level prerequisites.

- prerequisite behavior belongs in the native DAG and runner
- resource setup and cleanup ownership for real validations belongs in
  `src/Prodbox/TestValidation.hs` and the relevant infrastructure modules
- the suite-level managed IAM credential harness for `prodbox test integration aws-iam`,
  `prodbox test integration all`, and `prodbox test all` belongs in
  `src/Prodbox/TestRunner.hs` plus `src/Prodbox/Aws.hs`
- cleanup doctrine is defined by [Integration Fixture Doctrine](./integration_fixture_doctrine.md)

### Timeout Budget Separation

Prerequisite and runtime-preparation time should not be confused with payload execution time.

- earlier phases own readiness checks and runbook work
- Phase 2 owns Haskell suites and named validation payloads

## 3. Forbidden Patterns

Avoid:

- silent `skip` or `xfail` behavior for missing prerequisites
- hidden prerequisite setup outside the supported test runner
- mocking deep inside pure planning code
- raw ad-hoc file selectors as the public test interface
- undocumented destructive setup or teardown in named validations

## 4. Allowed Patterns

Allowed patterns include:

- pure helper tests in `test/unit/Main.hs`
- fake-tool built-frontend proof in `test/integration/cli/Main.hs`
- repository-local config proof in `test/integration/env/Main.hs`
- real named validation flows behind `prodbox test integration ...`
- explicit prerequisite and cleanup ownership in native Haskell modules

## 5. Test Data vs Mocks

Prefer concrete test data over mocks when the code under test is pure.

- use real ADT values for parsing and rendering tests
- use fake tool binaries or controlled subprocess environments for built-frontend proof
- reserve mocking-style indirection for true effect boundaries

## 6. pytest-subprocess Usage

The repository no longer uses a Python pytest harness on the supported path.

The equivalent doctrine in the current Haskell repository is:

- keep subprocess faking at the boundary
- test built-frontend command behavior through dedicated Haskell integration suites
- keep pure logic free of subprocess concerns

## 7. Coverage Targets

Coverage remains a repository expectation, but the supported local closure gate is the Haskell
build-plus-suite contract:

- `./.build/prodbox check-code`
- `./.build/prodbox test unit`
- `./.build/prodbox test integration cli`
- `./.build/prodbox test integration env`

Named real-world validation commands provide operational proof rather than synthetic line coverage.

## 8. Intent Ownership

This SSoT co-owns the public testing doctrine.

- Owned statement: `prodbox test` is a prerequisite-aware, phase-bannered Haskell test runner with
  explicit named validation ownership.
- Linked dependents: `src/Prodbox/TestPlan.hs`, `src/Prodbox/TestRunner.hs`,
  `src/Prodbox/TestValidation.hs`, `test/unit/Main.hs`, `test/integration/cli/Main.hs`,
  `test/integration/env/Main.hs`.

## Cross-References

- [CLI Command Surface](./cli_command_surface.md)
- [Code Quality Doctrine](./code_quality.md)
- [Envoy Gateway Edge Doctrine](./envoy_gateway_edge_doctrine.md)
- [Integration Fixture Doctrine](./integration_fixture_doctrine.md)
- [Streaming Doctrine](./streaming_doctrine.md)
