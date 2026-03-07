# Repository Guidelines for Agents

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: README.md, CLAUDE.md

> **Purpose**: Agent-facing repository rules for structure, tooling, and coding standards.

---

## Project Structure

```
prodbox/
├── src/prodbox/          # Main source package
│   ├── cli/              # Click CLI commands and DAG system
│   ├── infra/            # Pulumi infrastructure definitions
│   ├── lib/              # Shared utilities
│   └── settings.py       # Pydantic configuration
├── tests/                # Unit and integration tests
│   ├── unit/             # Pure function tests
│   └── integration/      # Real infrastructure tests
├── typings/              # Custom type stubs for external libs
├── documents/            # Engineering documentation
├── scripts/              # Systemd units for DDNS
└── pyproject.toml        # Poetry configuration
```

---

## Build, Test, and Development Commands

All commands through Poetry:

```bash
# Install dependencies
poetry install

# Run CLI
poetry run prodbox <command>

# Run tests
poetry run prodbox test                    # All tests
poetry run prodbox test -m "not integration"  # Unit only
poetry run prodbox test --cov=src/prodbox  # With coverage

# Code quality checks (canonical entrypoint)
poetry run prodbox check-code        # Policy guard + ruff + mypy
```

---

## Coding Style

### Python

- **Indentation**: 4 spaces (no tabs)
- **Line length**: 100 characters max
- **Type hints**: Required everywhere, no `Any` types
- **Docstrings**: Google style
- **Imports**: isort ordering (stdlib, third-party, first-party)

### Data Structures

> **SSoT**: [Pure FP Standards](documents/engineering/pure_fp_standards.md)

#### Immutability Requirements

ALL dataclasses MUST be frozen:

```python
# ✅ CORRECT
@dataclass(frozen=True)
class CommandResult:
    returncode: int
    stdout: str
    args: tuple[str, ...]

# ❌ WRONG
@dataclass
class CommandResult:
    returncode: int
    stdout: str
    args: list[str]
```

Use immutable collections:

| Instead of | Use |
|------------|-----|
| `list[T]` | `tuple[T, ...]` |
| `set[T]` | `frozenset[T]` |
| `dict[K, V]` (mutable) | `Mapping[K, V]` (parameter) |

#### Smart Constructor Pattern

Validate at construction time and return `Result`:

```python
def port_command(port: int) -> Result[PortCommand, str]:
    match port:
        case p if 1 <= p <= 65535:
            return Success(PortCommand(port=p))
        case _:
            return Failure(f"Invalid port: {port}")
```

#### ADT Exhaustiveness

Handle ALL cases explicitly - no catch-all defaults:

```python
from typing import Never

def _assert_never(value: object) -> Never:
    raise AssertionError(f"Unhandled case: {type(value).__name__}")

match command:
    case DNSUpdateCommand():
        return handle_dns_update(command)
    case K8sHealthCommand():
        return handle_k8s_health(command)
    case _ as unreachable:
        _assert_never(unreachable)  # Type-safe unreachable
```

#### Result Types for Error Handling (No Exceptions)

```python
def parse(s: str) -> Result[int, str]:
    match s.isdigit():
        case True:
            return Success(int(s))
        case False:
            return Failure(f"Invalid: {s}")
```

#### Exhaustive Pattern Matching (No Else Clauses)

```python
match result:
    case Success(value):
        return value
    case Failure(error):
        return handle_error(error)
```

---

## Testing Guidelines

### Unit Tests

- Test pure functions in isolation
- Use pytest-subprocess for subprocess mocking
- Block unregistered subprocess calls (defense-in-depth)

```python
def test_parse_success(fp: FakeProcess) -> None:
    fp.register(["kubectl", "version"], stdout="v1.28.0")
    result = parse_kubectl_version()
    assert result == "1.28.0"
```

### Integration Tests

- Mark with `@pytest.mark.integration`
- Require real infrastructure (kubectl, RKE2, etc.)
- Missing prerequisites must fail fast with actionable errors (no skip/xfail policy)
- CI executes unit suites (`-m "not integration"`) unless integration environment is explicitly provisioned

### Coverage

- Target: 100% for prodbox code
- Exclude: test files, `if __name__ == "__main__"` blocks

---

## Commit Guidelines

**CRITICAL: Agents NEVER commit or push.**

- Leave ALL changes as uncommitted working directory changes
- Do NOT run `git commit`, `git push`, `git add`
- Do NOT run any git commands that modify repository state
- User reviews and commits manually

This policy ensures human oversight of all code changes.

---

## Security

- **Never commit `.env` files** - secrets only via environment
- **AWS credentials via environment only** - never hardcode
- **Validate all external input** - especially FQDN, IP addresses
- **Least privilege IAM** - Route 53 + STS only

---

## Type Safety

Ultra-strict mypy configuration:
Use `poetry run prodbox check-code` as the only supported entrypoint for type checks.

```toml
[tool.mypy]
strict = true
disallow_any_unimported = true
disallow_any_expr = true
disallow_any_explicit = true
disallow_any_generics = true
```

Custom stubs in `typings/` for:
- Click, Pulumi, boto3, botocore, rich, pytest

---

## Cross-References

- **CLAUDE.md**: Detailed AI assistant guidelines
- **documents/documentation_standards.md**: Documentation rules
- **documents/engineering/**: Architecture documentation
