# Engineering Documentation

**Status**: Reference only
**Supersedes**: N/A
**Referenced by**: README.md

> **Purpose**: Index of engineering and architecture documentation.

SSoT ownership, bidirectional links, and non-duplication rules are mandatory for all new doctrinal content.

---

## Documents

| Document | Purpose |
|----------|---------|
| [dependency_management.md](./dependency_management.md) | Poetry dependency standards |
| [distributed_gateway_architecture.md](./distributed_gateway_architecture.md) | Multi-node gateway leadership and failover design |
| [effectful_dag_architecture.md](./effectful_dag_architecture.md) | Effect DAG system design |
| [effect_interpreter.md](./effect_interpreter.md) | Interpreter runtime execution contract |
| [local_registry_pipeline.md](./local_registry_pipeline.md) | Harbor installation + local image mirror pipeline |
| [storage_lifecycle_doctrine.md](./storage_lifecycle_doctrine.md) | Retained storage + deterministic PVC/PV rebinding doctrine |
| [prerequisite_doctrine.md](./prerequisite_doctrine.md) | Fail-fast prerequisite philosophy |
| [prerequisite_dag_system.md](./prerequisite_dag_system.md) | Prerequisite DAG construction and runtime reference |
| [streaming_doctrine.md](./streaming_doctrine.md) | Streaming and at-most-one-stream invariants |
| [tla/README.md](./tla/README.md) | TLA+ model index for formal safety properties |
| [tla_modelling_assumptions.md](./tla_modelling_assumptions.md) | TLA+ formal model correspondence, divergences, and verification status |
| [unit_testing_policy.md](./unit_testing_policy.md) | Interpreter-Only Mocking Doctrine |
| [pure_fp_standards.md](./pure_fp_standards.md) | Pure FP coding standards |
| [code_quality.md](./code_quality.md) | Policy guardrails and check-code gate |
| [refactoring_patterns.md](./refactoring_patterns.md) | Imperative to pure FP migration patterns |

---

## Quick Navigation

### Effect DAG System
- [Effect Types](./effectful_dag_architecture.md#3-effect-types)
- [DAG Construction](./effectful_dag_architecture.md#4-dag-construction)
- [Interpreter Pattern](./effectful_dag_architecture.md#5-interpreter-pattern)
- [Interpreter Runtime Contract](./effect_interpreter.md#1-runtime-parity-statement)
- [Streaming Contract](./streaming_doctrine.md#1-streaming-contract-statement)

### Distributed Gateway
- [Architecture](./distributed_gateway_architecture.md)
- [Local Registry Pipeline](./local_registry_pipeline.md)
- [Gateway Container Build Doctrine](./local_registry_pipeline.md#6-gateway-container-build-doctrine)
- [Storage Lifecycle Doctrine](./storage_lifecycle_doctrine.md)
- [TLA+ Models](./tla/README.md)
- [TLA+ Modelling Assumptions](./tla_modelling_assumptions.md)

### Prerequisites
- [Fail-Fast Philosophy](./prerequisite_doctrine.md#1-philosophy)
- [Prerequisite Registry](./prerequisite_doctrine.md#3-registry)
- [Prerequisite DAG System](./prerequisite_dag_system.md)

### Dependency Management
- [Lock File Policy](./dependency_management.md#1-lock-file-policy)
- [Version Constraint Standards](./dependency_management.md#2-version-constraint-standards)

### Unit Testing
- [Interpreter-Only Mocking Doctrine](./unit_testing_policy.md#1-the-interpreter-only-mocking-doctrine)
- [Forbidden Patterns](./unit_testing_policy.md#3-forbidden-patterns)
- [Allowed Patterns](./unit_testing_policy.md#4-allowed-patterns)
- [Two-Phase Test Command Doctrine](./unit_testing_policy.md#two-phase-test-command-doctrine)

### Code Quality
- [Code Quality Doctrine](./code_quality.md)
- [Pure FP Standards](./pure_fp_standards.md)

---

## Intent Ownership

This index co-owns documentation-topology doctrine intention.

- Owned statement: SSoT ownership, bidirectional links, and non-duplication rules are mandatory for all new doctrinal content.
- Linked dependents: [Documentation Standards](../documentation_standards.md), [Code Quality Doctrine](./code_quality.md).

---

## Cross-References

- [Documentation Standards](../documentation_standards.md)
- [CLAUDE.md](../../CLAUDE.md)
- [AGENTS.md](../../AGENTS.md)
