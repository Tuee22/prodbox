# Unit Testing Policy

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: README.md, AGENTS.md, CLAUDE.md, DEVELOPMENT_PLAN/README.md, documents/engineering/README.md, documents/engineering/aws_integration_environment_doctrine.md, documents/engineering/aws_test_environment.md, documents/engineering/cli_command_surface.md, documents/engineering/code_quality.md, documents/engineering/distributed_gateway_architecture.md, documents/engineering/helm_chart_platform_doctrine.md, documents/engineering/integration_fixture_doctrine.md, documents/engineering/prerequisite_dag_system.md, documents/engineering/streaming_doctrine.md

> **Purpose**: Define the Interpreter-Only Mocking Doctrine for unit tests in prodbox.

---

## 0. Canonical Skip Policy Statement

Skip/xfail is prohibited by default; any allowed exception requires explicit doctrinal criteria and automated enforcement.

The test suite cannot enumerate every partition/failure schedule; robust integration tests remain mandatory to validate TLA+ modelling choices against the implementation.

When a selected integration suite requires cluster-backed runtime preparation, `prodbox test` must enforce the runbook by executing `prodbox rke2 install` before pytest.

`prodbox test` phase-two pytest timeout budget is capped at 240 minutes (14,400 seconds).

This document defines testing doctrine only. Clean-room sequencing, completion
status, remaining work, and legacy-path removal are owned by
[DEVELOPMENT_PLAN/README.md](../../DEVELOPMENT_PLAN/README.md).

Current implementation split:
- `src/Prodbox/TestRunner.hs` owns the public `prodbox test` entrypoint and runs the Haskell
  suites under `test/`.
- `src/Prodbox/Effect.hs`, `src/Prodbox/EffectDAG.hs`, `src/Prodbox/EffectInterpreter.hs`,
  `src/Prodbox/Prerequisite.hs`, `src/Prodbox/Subprocess.hs`, `src/Prodbox/SupportedRuntime.hs`,
  and `src/Prodbox/TestPlan.hs` now own phase banners, prerequisite closure, runbook gating,
  canonical aggregate ordering, supported-runtime bootstrap/postflight sequencing,
  multi-invocation coverage handling, and direct pytest invocation across the public suite surface.
- Retained `src/prodbox/cli/test_cmd.py` now survives only as the legacy direct-backend `test`
  implementation under `PRODBOX_PYTHON_BACKEND=1`.
- `test/integration/cli/Main.hs` now exercises the built frontend directly, including fake-AWS
  end-to-end proof for the native `config setup` and `aws ...` command family, fake-curl proof
  for native `gateway status` and `gateway config-gen`, native fake-`helm` or `kubectl` proof for
  `prodbox charts list|status|deploy|delete`, fake host / `kubectl` / `helm` / `docker` / `ctr`
  proof for native `prodbox rke2 install|delete`, and fake-backend delegation proof that remains
  only for the unfinished Pulumi AWS-validation and `gateway start` shim surfaces.
- `test/integration/env/Main.hs` now owns direct built-frontend proof for native `config show`
  and `config validate` masking, failure, and JSON materialization behavior, so `prodbox test
  integration env` no longer delegates to a retained Python env pytest suite.

---

## 1. The Interpreter-Only Mocking Doctrine

### Core Rule

**Pure code never touches mocks. All mocking happens in the interpreter.**

The interpreter is the impurity boundary. Pure code produces effect data structures; the interpreter executes them. Mocks for external systems (kubectl, AWS, subprocess) are injected into the interpreter, never into pure code.

### Why This Matters

1. **Purity guarantee**: Pure code never imports or references mocks - it only produces data
2. **Single mock location**: All mocking is centralized in the interpreter
3. **Clear boundary**: If you need to mock something in pure code, that code is impure and must be refactored
4. **Testability**: Pure functions are trivially testable with no setup required

---

## 2. Unit vs Integration Tests

| Aspect | Unit Test | Integration Test |
|--------|-----------|------------------|
| External systems | Mocked via interpreter | Real |
| Speed | Fast | Slow |
| Dependencies | None | kubectl, AWS, etc. |
| Where mocks live | Interpreter only | N/A |
| Markers | None | `@pytest.mark.integration` |

### Test Categories

| Category | Mocking | What Gets Tested |
|----------|---------|------------------|
| Pure function tests | **None needed** | Effect types, DAG builders, smart constructors, Result ADT |
| Interpreter unit tests | **Mocked externals** | Interpreter methods with pytest-subprocess, mocked boto3 |
| Integration tests | **None (real systems)** | Full pipeline with real kubectl, AWS, Pulumi |

Stateful AWS-mutating integration tests must follow
[AWS Integration Environment Doctrine](./aws_integration_environment_doctrine.md) instead of
reusing existing AWS resources. In the supported architecture that means per-test Route 53 hosted
zone fixtures for `dns-aws`, Pulumi-owned AWS stack lifecycle for `aws-eks`, `pulumi`, and
`ha-rke2-aws`, setup rollback before yield where fixtures allocate resources directly, and
aggregate postflight destroy through the supported `prodbox test all` flow.

### Integration Execution Policy (Fail-Fast)

- Integration tests must fail fast when prerequisites are missing.
- Platform/environment gating belongs in prerequisite validation, not inside pytest skips.
- For unit-only environments without integration infrastructure, run `poetry run prodbox test unit`.

### Two-Phase Test Command Doctrine

Integration-selected `prodbox test` suite commands execute in two phases:

1. **Phase 1 - prerequisite gate**: when integration scope is selected, the eDAG validates integration prerequisites before pytest starts.
2. **Phase 1.5 - integration runbook gate**: cluster-backed integration suites enforce `prodbox rke2 install`.
3. **Phase 2 - test execution**: pytest runs only after Phase 1 and any required Phase 1.5 gate succeed.

When a selected integration suite requires cluster-backed runtime preparation, `prodbox test` must enforce the runbook by executing `prodbox rke2 install` before pytest.

If Phase 1 fails, pytest is not started. This is an all-or-nothing gate, not a skip.

### Phase Banner Rendering Contract

`prodbox test` phase banners are operator-facing progress records. Their visible order and line framing are part of the command contract.

1. Visible banner order is exact: `Phase 1/2`, optional `Phase 1.5/2`, then `Phase 2/2`.
2. Each phase banner is emitted as its own stdout line.
3. The `Phase 1.5/2` banner is emitted if and only if the selected suite requires the cluster runbook.
4. The `Phase 2/2` banner is emitted only after the prerequisite gate succeeds and, when required by the selected suite, after `prodbox rke2 install` succeeds.
5. Generic terminal record framing rules are owned by [Streaming Doctrine](./streaming_doctrine.md#5-terminal-record-contract).

### Command-Scope Prerequisite Aggregation

`prodbox test` applies prerequisite gates at command scope:

1. Selected named Click suite determines whether integration prerequisites are required.
2. Integration-selected scopes aggregate prerequisite requirements into one Phase 1 gate.
3. Unit-only scope (`poetry run prodbox test unit`) bypasses integration gates.
4. External public-host suites such as `charts-vscode` and `public-dns` may run with an empty prerequisite gate and no cluster runbook.
5. Aggregate suites (`prodbox test integration all` and `prodbox test all`) use an explicit
   canonical file order so public-host proof runs before cluster-backed teardown suites,
   `test_aws_eks.py` runs after Route 53-only AWS validation and before `test_pulumi_real.py`,
   `test_charts_platform.py` runs before `test_charts_storage.py` to clear shared singleton
   release names, and the lifecycle cleanup suite remains last.
6. Aggregate suites never delete and redeploy the live public host as part of Phase 1.5. They
   require `prodbox host public-edge` to report `CLASSIFICATION=ready-for-external-proof` before
   Phase 2 pytest starts.
7. Aggregate suites restore the supported runtime after the destructive pytest tail by running
   `prodbox pulumi refresh`, `prodbox pulumi up --yes`, `prodbox charts deploy gateway`,
   `prodbox charts deploy vscode`, `prodbox pulumi eks-destroy --yes`, and
   `prodbox pulumi test-destroy --yes`, then wait for `prodbox host public-edge` to return
   `CLASSIFICATION=ready-for-external-proof` before exit.
8. Aggregate supported-runtime repair helpers must idempotently select or create the canonical
   Pulumi `home` stack before raw Pulumi AWS/provider repair runs; no supported aggregate rerun
   depends on a manual `pulumi stack select`.

### Session Fixtures vs Test DAG (SSoT)

Session fixtures are for pytest infrastructure only. CLI-modeled effectful prerequisites belong in the test DAG.

- Allowed in session fixtures: pure pytest setup, temporary directory scaffolding, plugin configuration.
- Forbidden in session fixtures: invoking `poetry run prodbox ...`, starting external services, or running CLI-modeled prerequisite operations.

This keeps prerequisite orchestration centralized in the eDAG gate and prevents hidden preconditions.

Cluster-backed pytest setup/teardown ownership, cleanup guarantees, and cleanup-failure handling are defined in [Integration Fixture Doctrine](./integration_fixture_doctrine.md).

### Timeout Budget Separation

Two-phase execution separates timeout budgets:

1. Phase 1 prerequisite gate uses command-level timeout budgets (for example, integration prerequisite checks).
2. Phase 2 pytest execution uses test-level timeout policy (`pytest-timeout`, per-test overrides as needed).
3. Phase 1 elapsed time does not consume Phase 2 test timeout budget.

---

## 3. Forbidden Patterns

### Coverage Exclusions

```python
# ❌ FORBIDDEN: Coverage exclusion pragma
if some_condition:  # pragma: no cover
    ...
```

**Why no pragma**: Every line of code must be testable. If a line seems untestable, it indicates a design issue that should be fixed, not excluded. Coverage exclusions hide technical debt and create false confidence in test coverage.

### Mocking Inside Pure Code

```python
# ❌ FORBIDDEN: Mocking inside pure code (DAG builder)
@patch("prodbox.cli.dag_builders.some_external_thing")
def test_dag_builder() -> None:
    ...

# ❌ FORBIDDEN: Pure code importing/using mocks
def build_dns_dag(mock_client: Mock) -> EffectDAG:  # Pure code with mock parameter!
    ...

# ❌ FORBIDDEN: Mocks imported in pure modules
from unittest.mock import Mock
# ... in a DAG builder or effect module
```

### Skip/XFail Constructs

```python
# ❌ FORBIDDEN: Runtime test skips
pytest.skip("cluster not available")

# ❌ FORBIDDEN: Skip decorators
@pytest.mark.skip(reason="missing dependency")
def test_example() -> None:
    ...

# ❌ FORBIDDEN: Conditional skip decorators
@pytest.mark.skipif(True, reason="not on linux")
def test_linux_only() -> None:
    ...

# ❌ FORBIDDEN: Expected-failure markers
@pytest.mark.xfail(reason="known failure")
def test_known_bug() -> None:
    ...
```

Tests must either pass or fail with actionable prerequisite errors. Silent skips and expected-failure
markers hide infrastructure regressions and reduce test signal quality.

### Specific Anti-Patterns

- `# pragma: no cover` - Coverage exclusions are never permitted
- `@patch("prodbox.cli.dag_builders.*")` - Mocking inside pure code
- `@patch("prodbox.cli.effects.*")` - Mocking effect construction
- Pure functions with `Mock` or `MagicMock` parameters
- Mocks imported in any module except `interpreter.py` tests
- `pytest.skip(...)` and `pytest.xfail(...)` in tests
- `@pytest.mark.skip`, `@pytest.mark.skipif`, `@pytest.mark.xfail`

---

## 4. Allowed Patterns

### Pure Function Tests (No Mocks)

```python
# ✅ CORRECT: Pure function test - no mocks needed
def test_dag_builder_produces_correct_prerequisites() -> None:
    # settings is test data (frozen dataclass), not a mock
    settings = Settings(domain="example.com", ...)
    dag = dns_update_dag(settings)
    assert "aws_credentials_valid" in dag.root.prerequisites
```

### Interpreter Tests (Mocked Externals)

```python
# ✅ CORRECT: Mocks live in interpreter setup
async def test_kubectl_get_nodes(fp: FakeProcess) -> None:
    # pytest-subprocess mocks the external system
    fp.register(["kubectl", "get", "nodes", "-o", "json"], stdout='{"items": []}')

    effect = RunKubectl(args=("get", "nodes", "-o", "json"))
    interpreter = EffectInterpreter()
    summary = await interpreter.interpret(effect)

    assert summary.exit_code == 0
```

### Full Pipeline Tests (Mocked Interpreter)

```python
# ✅ CORRECT: Test full pipeline with mocked interpreter
async def test_dns_check_command(fp: FakeProcess) -> None:
    # Mock externals at interpreter level
    fp.register(["curl", fp.any()], stdout="1.2.3.4")

    # Pure code produces the DAG
    cmd = dns_check_command()
    match cmd:
        case Success(command):
            dag = command_to_dag(command)
            # Interpreter executes with mocked externals
            summary = await interpreter.execute(dag)
            assert summary.exit_code == 0
```

---

## 5. Test Data vs Mocks

### Test Data (Allowed Everywhere)

Test data are frozen dataclass instances used as inputs to pure functions:

```python
# Test data - just a frozen dataclass instance
settings = Settings(
    domain="example.com",
    email="test@example.com",
    aws_region="us-east-1",
)

# Used in pure function test
dag = dns_update_dag(settings)
```

### Mocks (Interpreter Only)

Mocks simulate external systems and are only used in interpreter tests:

```python
# Mock - only in interpreter tests
fp.register(["kubectl", "get", "nodes"], stdout="...")

# Mock boto3 client - only in interpreter
mock_route53 = MagicMock()
mock_route53.list_resource_record_sets.return_value = {...}
```

---

## 6. pytest-subprocess Usage

The `pytest-subprocess` library (`fp` fixture) is the primary tool for mocking subprocess calls in interpreter tests:

```python
import pytest
from pytest_subprocess import FakeProcess

async def test_systemd_status(fp: FakeProcess) -> None:
    fp.register(
        ["systemctl", "is-active", "rke2-server"],
        stdout="active",
        returncode=0,
    )

    effect = RunSystemctl(args=("is-active", "rke2-server"))
    interpreter = EffectInterpreter()
    summary = await interpreter.interpret(effect)

    assert summary.exit_code == 0
```

### Key Rules

1. `fp.register()` must be called BEFORE the interpreter runs
2. Use `fp.any()` for variable arguments
3. Always specify `returncode` for non-zero exits
4. Register all expected subprocess calls (unregistered calls fail)

---

## 7. Coverage Targets

| Module | Target |
|--------|--------|
| All modules (excluding `infra/`) | **100%** |

### True 100% Coverage

All code must have 100% test coverage. This is enforced by:

```bash
poetry run prodbox test all --coverage --cov-fail-under 100
```

If a line of code cannot be covered by tests, the code must be refactored to make it testable. Common solutions:

1. **Platform-specific code**: Use `platform.system()` patches in tests
2. **Error handling**: Create mocked error scenarios (network failures, file not found, etc.)
3. **Async timeout paths**: Use short timeouts in tests to trigger timeout branches
4. **Exception branches**: Construct scenarios that raise exceptions

### Exclusions

The `infra/` module is excluded from unit test coverage because it requires a real Pulumi runtime. This code is covered by integration tests only.

---

## 8. Intent Ownership

This SSoT owns test skip doctrine intention.

- Owned statement: Skip/xfail is prohibited by default; any allowed exception requires explicit doctrinal criteria and automated enforcement.
- Linked dependents: `src/prodbox/lib/lint/no_test_skip_guard.py`, `src/Prodbox/TestRunner.hs`, `src/Prodbox/TestPlan.hs`, `src/prodbox/cli/test_cmd.py`.

---

## Cross-References

- [Development Plan](../../DEVELOPMENT_PLAN/README.md)
- [Pure FP Standards](./pure_fp_standards.md) - Purity boundary definitions
- [Code Quality Doctrine](./code_quality.md) - Guardrail enforcement
- [Effectful DAG Architecture](./effectful_dag_architecture.md) - Effect system design
- [Prerequisite DAG System](./prerequisite_dag_system.md) - Test prerequisite gate construction
- [CLI Command Surface](./cli_command_surface.md) - Explicit command matrix
- [CLAUDE.md](../../CLAUDE.md) - Project overview
