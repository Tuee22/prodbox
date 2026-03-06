# Unit Testing Policy

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: CLAUDE.md, documents/engineering/README.md

> **Purpose**: Define the Interpreter-Only Mocking Doctrine for unit tests in prodbox.

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

### Specific Anti-Patterns

- `# pragma: no cover` - Coverage exclusions are never permitted
- `@patch("prodbox.cli.dag_builders.*")` - Mocking inside pure code
- `@patch("prodbox.cli.effects.*")` - Mocking effect construction
- Pure functions with `Mock` or `MagicMock` parameters
- Mocks imported in any module except `interpreter.py` tests

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
async def test_dns_update_command(fp: FakeProcess) -> None:
    # Mock externals at interpreter level
    fp.register(["curl", fp.any()], stdout="1.2.3.4")

    # Pure code produces the DAG
    cmd = dns_update_command(force=True)
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
poetry run prodbox test --cov=src/prodbox --cov-fail-under=100
```

If a line of code cannot be covered by tests, the code must be refactored to make it testable. Common solutions:

1. **Platform-specific code**: Use `platform.system()` patches in tests
2. **Error handling**: Create mocked error scenarios (network failures, file not found, etc.)
3. **Async timeout paths**: Use short timeouts in tests to trigger timeout branches
4. **Exception branches**: Construct scenarios that raise exceptions

### Exclusions

The `infra/` module is excluded from unit test coverage because it requires a real Pulumi runtime. This code is covered by integration tests only.

---

## Cross-References

- [Pure FP Standards](./pure_fp_standards.md) - Purity boundary definitions
- [Effectful DAG Architecture](./effectful_dag_architecture.md) - Effect system design
- [CLAUDE.md](../../CLAUDE.md) - Project overview
