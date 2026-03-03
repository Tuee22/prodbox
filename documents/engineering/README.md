# Engineering Documentation

**Status**: Reference only
**Supersedes**: N/A
**Referenced by**: README.md

> **Purpose**: Index of engineering and architecture documentation.

---

## Documents

| Document | Purpose |
|----------|---------|
| [dependency_management.md](./dependency_management.md) | Poetry dependency standards |
| [distributed_gateway_architecture.md](./distributed_gateway_architecture.md) | Multi-node gateway leadership and failover design |
| [effectful_dag_architecture.md](./effectful_dag_architecture.md) | Effect DAG system design |
| [prerequisite_doctrine.md](./prerequisite_doctrine.md) | Fail-fast prerequisite philosophy |
| [tla/README.md](./tla/README.md) | TLA+ model index for formal safety properties |
| [tla_modelling_assumptions.md](./tla_modelling_assumptions.md) | TLA+ formal model correspondence, divergences, and verification status |
| [unit_testing_policy.md](./unit_testing_policy.md) | Interpreter-Only Mocking Doctrine |
| [pure_fp_standards.md](./pure_fp_standards.md) | Pure FP coding standards |
| [refactoring_patterns.md](./refactoring_patterns.md) | Imperative to pure FP migration patterns |

---

## Quick Navigation

### Effect DAG System
- [Effect Types](./effectful_dag_architecture.md#effect-types)
- [DAG Construction](./effectful_dag_architecture.md#dag-construction)
- [Interpreter Pattern](./effectful_dag_architecture.md#interpreter-pattern)

### Distributed Gateway
- [Architecture](./distributed_gateway_architecture.md)
- [TLA+ Models](./tla/README.md)
- [TLA+ Modelling Assumptions](./tla_modelling_assumptions.md)

### Prerequisites
- [Fail-Fast Philosophy](./prerequisite_doctrine.md#philosophy)
- [Prerequisite Registry](./prerequisite_doctrine.md#registry)

### Dependency Management
- [Lock File Policy](./dependency_management.md#1-lock-file-policy)
- [Version Constraint Standards](./dependency_management.md#2-version-constraint-standards)

### Unit Testing
- [Interpreter-Only Mocking Doctrine](./unit_testing_policy.md#1-the-interpreter-only-mocking-doctrine)
- [Forbidden Patterns](./unit_testing_policy.md#3-forbidden-patterns)
- [Allowed Patterns](./unit_testing_policy.md#4-allowed-patterns)

---

## Cross-References

- [Documentation Standards](../documentation_standards.md)
- [CLAUDE.md](../../CLAUDE.md)
- [AGENTS.md](../../AGENTS.md)
