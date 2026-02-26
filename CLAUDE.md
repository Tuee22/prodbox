# Claude Code Patterns for Prodbox

**Status**: Reference only
**Referenced by**: README.md, documents/engineering/README.md

> **Purpose**: Guide for Claude Code development on prodbox - home Kubernetes infrastructure management with Pulumi.

---

## Project Overview

Prodbox is a Python-native infrastructure-as-code project for managing a home Kubernetes cluster. It provides declarative, idempotent CLI commands for deploying and managing:

- **RKE2**: Lightweight Kubernetes distribution
- **MetalLB**: Bare-metal load balancer
- **Traefik**: Ingress controller
- **cert-manager**: Automatic TLS certificate management
- **Route 53**: AWS DNS with dynamic DNS updates

**Stack**: Python 3.12 + Click CLI + Pydantic + Pulumi IaC

---

## Git Workflow Policy

**CRITICAL: Claude Code is NOT authorized to commit or push changes.**

- NEVER run `git commit`, `git push`, `git add`, or any git commands that modify repository state
- Leave ALL changes as uncommitted working directory changes
- User reviews and commits manually
- This policy ensures human oversight of all code changes

---

## Pure FP Doctrine

> **SSoT**: [Pure FP Standards](documents/pure_fp_standards.md)

### Purity Boundary

| Code Location | Purity | Allowed |
|---------------|--------|---------|
| DAG builders, smart constructors, utilities | 100% pure | Nothing impure |
| Interpreter `_interpret_*` methods | Impure | Mutation, I/O, try/except |
| Command entry points | Impure | `sys.exit()` only |

### Key Rules

1. **No mutation outside interpreter** - Use `@dataclass(frozen=True)`, `tuple`, `frozenset`
2. **No if/else** - Use `match/case` with exhaustive patterns
3. **No for loops in pure code** - Use comprehensions or `reduce`
4. **No exceptions for control flow** - Return `Result[T, E]`
5. **No default case handlers** - Handle all ADT variants explicitly

### Quick Example

```python
# ✅ CORRECT - Pure DAG builder
def dns_update_dag(settings: Settings) -> EffectDAG:
    return EffectDAG.from_roots(
        EffectNode(
            effect=UpdateRoute53Record(...),
            prerequisites=frozenset(["aws_credentials_valid"])
        ),
        registry=PREREQUISITE_REGISTRY
    )

# ❌ WRONG - Impure code with side effects
def update_dns(settings: Settings) -> None:
    try:
        ip = get_public_ip()  # I/O!
        print(f"IP: {ip}")    # Side effect!
    except Exception as e:
        sys.exit(1)           # Scattered exit!
```

See [Refactoring Patterns](documents/refactoring_patterns.md) for migration guides.

---

## Architecture

### Directory Structure

```
prodbox/
├── src/prodbox/
│   ├── cli/                  # Click CLI commands
│   │   ├── main.py           # Entry point
│   │   ├── context.py        # Settings context
│   │   ├── types.py          # Result ADT, subprocess types
│   │   ├── effects.py        # Effect ADT hierarchy (50+ effect types)
│   │   ├── effect_dag.py     # DAG types and prerequisite expansion
│   │   ├── interpreter.py    # Effect interpreter (impurity boundary)
│   │   ├── dag_builders.py   # Pure Command -> DAG transformations
│   │   ├── command_adt.py    # Command ADTs with smart constructors
│   │   ├── command_executor.py # Single entry point for execution
│   │   ├── prerequisite_registry.py # Prerequisite definitions
│   │   ├── env.py            # Configuration commands
│   │   ├── host.py           # Host prerequisite commands
│   │   ├── rke2.py           # RKE2 management commands
│   │   ├── pulumi_cmd.py     # Pulumi commands
│   │   ├── dns.py            # Route 53 DNS commands
│   │   └── k8s.py            # Kubernetes health commands
│   ├── infra/                # Pulumi infrastructure definitions
│   │   ├── __main__.py       # Pulumi program orchestrator
│   │   ├── providers.py      # K8s and AWS providers
│   │   ├── metallb.py        # MetalLB deployment
│   │   ├── ingress.py        # Traefik ingress
│   │   ├── cert_manager.py   # cert-manager installation
│   │   ├── cluster_issuer.py # ACME ClusterIssuer
│   │   └── dns.py            # Route 53 DNS records
│   ├── lib/                  # Shared utilities
│   │   ├── subprocess.py     # Async subprocess runner
│   │   ├── async_runner.py   # Click-asyncio bridge
│   │   ├── logging.py        # Rich logging setup
│   │   └── exceptions.py     # Custom exceptions
│   └── settings.py           # Pydantic configuration
├── tests/                    # Unit and integration tests
├── typings/                  # Custom type stubs
├── documents/                # Engineering documentation
├── CLAUDE.md                 # This file
└── AGENTS.md                 # Agent guidelines
```

### Design Patterns

1. **Pure Effectful DAG System** (implemented):
   - Effects describe side effects declaratively (50+ effect types)
   - DAG prerequisite system ensures dependencies
   - Railway pattern (`Result[T, E]`) for error handling
   - Single entry point for command execution (`execute_command()`)
   - CLI commands are thin wrappers that call the effect system

2. **Pydantic Configuration**:
   - Single `Settings` class for all configuration
   - Environment variable-based configuration
   - Validation on load with actionable errors

3. **CLI Command Pattern**:
   - Commands use smart constructors returning `Result[Command, str]`
   - DAG builders transform Commands to Effect DAGs (pure)
   - Interpreter executes effects (impurity boundary)
   - Rich library for colored terminal output

---

## Python CLI Tool (prodbox)

All operations via Poetry:

```bash
# Install
poetry install

# Run CLI
poetry run prodbox --help
poetry run prodbox env validate      # Validate configuration
poetry run prodbox env show          # Display configuration
poetry run prodbox host ensure-tools # Check required tools
poetry run prodbox pulumi preview    # Preview infrastructure changes
poetry run prodbox pulumi up --yes   # Deploy infrastructure
poetry run prodbox dns check         # Check DNS status
poetry run prodbox dns update        # Update DDNS
poetry run prodbox k8s health        # Check cluster health
```

---

## Type Safety

**Zero tolerance for `Any` types in prodbox code.**

The project uses ultra-strict mypy configuration:
- `disallow_any_expr = true`
- `disallow_any_explicit = true`
- `disallow_any_generics = true`
- `disallow_any_unimported = true`

Custom type stubs in `typings/` provide full typing for external libraries:
- Click, Pulumi, boto3, botocore, rich

**Exception**: Pulumi and boto3 libraries have unavoidable `Any` from their dynamic APIs. These are isolated behind typed wrapper interfaces.

---

## Infrastructure Patterns

### Pulumi Resources

- Use explicit providers (k8s_provider, aws_provider)
- Export meaningful outputs for debugging
- Follow dependency ordering in `__main__.py`
- Pin chart versions for reproducibility

### Kubernetes

- Namespace isolation for each component
- Helm for complex deployments (MetalLB, Traefik, cert-manager)
- Raw K8s manifests for ClusterIssuer, IPAddressPool

### AWS

- Route 53 for DNS management
- IAM least-privilege (Route 53 + STS only)
- DNS-01 ACME validation for Let's Encrypt

---

## Testing Philosophy

> **SSoT**: [Unit Testing Policy](documents/engineering/unit_testing_policy.md)

### Interpreter-Only Mocking Doctrine

**Pure code never touches mocks. All mocking happens in the interpreter.**

| Test Type | External System Mocking | What Gets Tested |
|-----------|-------------------------|------------------|
| **Unit tests** | Via interpreter (mocked effects) | Full pipeline with mocked external systems |
| **Integration tests** | None (real effects) | Full pipeline with real external systems |
| **Pure function tests** | None needed | Effect types, DAG builders, smart constructors |

### Key Rules

1. **Mocks live in interpreter only** - Use pytest-subprocess for subprocess mocking
2. **Pure code produces data** - Never import or reference mocks in pure modules
3. **Test data vs mocks** - Frozen dataclass instances are test data, not mocks
4. **Integration tests** - Marked with `@pytest.mark.integration`

### Coverage Targets

| Module | Target |
|--------|--------|
| Pure code (`effects.py`, `dag_builders.py`, etc.) | 100% |
| `interpreter.py` | 90%+ |
| CLI modules | 90%+ |
| Overall (excluding `infra/`) | 95%+ |

```bash
poetry run pytest                    # Run all tests
poetry run pytest -m "not integration"  # Unit tests only
poetry run pytest --cov=src/prodbox  # With coverage
```

---

## Quality Checks

```bash
poetry run mypy src/                 # Type checking (ultra-strict)
poetry run ruff check src/ tests/    # Linting
poetry run ruff format src/ tests/   # Formatting
```

---

## Common Development Tasks

### Adding a New CLI Command

1. Add Command ADT to `src/prodbox/cli/command_adt.py` with smart constructor
2. Add DAG builder to `src/prodbox/cli/dag_builders.py`
3. Update `command_to_dag()` pattern matching in `dag_builders.py`
4. Create thin wrapper in appropriate CLI module (e.g., `dns.py`)
5. Register command group in `main.py` (if new group)
6. Add tests in `tests/unit/` and/or `tests/integration/`
7. Run `poetry run mypy src/` to verify types
8. Leave changes uncommitted for review

### Modifying Infrastructure

1. Edit modules in `src/prodbox/infra/`
2. Run `poetry run prodbox pulumi preview` to verify
3. Test with `poetry run prodbox pulumi up --yes`
4. Leave changes uncommitted for review

---

## Dependency Management

> **SSoT**: [Dependency Management Standards](documents/engineering/dependency_management.md)

### Key Rules

1. **`poetry.lock` is NOT version controlled** - Each developer generates locally via `poetry install`
2. **All dependencies use caret bounds** - `package = "^X.Y.0"` for SemVer-compatible updates
3. **No unbounded dependencies** - Every package must have an explicit upper bound

### Adding Dependencies

```bash
# Runtime dependency with caret bound
poetry add "package^X.Y.0"

# Dev dependency
poetry add --group dev "package^X.Y.0"
```

---

## Engineering Documentation

See `documents/engineering/` for detailed architecture docs:
- `dependency_management.md` - Poetry dependency standards
- `effectful_dag_architecture.md` - DAG system design
- `prerequisite_doctrine.md` - Fail-fast vs auto-rebuild philosophy
- `unit_testing_policy.md` - Interpreter-Only Mocking Doctrine

---

## Contributing Checklist

- [ ] Code changes implemented
- [ ] Tests written and passing (`poetry run pytest`)
- [ ] Type checking passes (`poetry run mypy src/`)
- [ ] Linting passes (`poetry run ruff check .`)
- [ ] **Changes left uncommitted** (user commits manually)
