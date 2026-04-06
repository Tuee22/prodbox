# Engineering Documentation

**Status**: Reference only
**Supersedes**: N/A
**Referenced by**: README.md, DEVELOPMENT_PLAN/README.md, documents/documentation_standards.md, documents/engineering/aws_test_environment.md

> **Purpose**: Index of engineering and architecture documentation.

SSoT ownership, bidirectional links, and non-duplication rules are mandatory for all new doctrinal content.

---

## Roadmap

Clean-room build order, current sprint status, blockers, validation closure,
and legacy-path removal are tracked only in
[DEVELOPMENT_PLAN/README.md](../../DEVELOPMENT_PLAN/README.md).

The documents in this directory are stable doctrine and architecture references. They
should describe the canonical rules and contracts, not carry competing sprint-status
reports.

---

## Documents

| Document | Purpose |
|----------|---------|
| [aws_test_environment.md](./aws_test_environment.md) | Shared AWS member-account, DNS, isolation, lifecycle, and auth doctrine for ephemeral multi-project testing |
| [dependency_management.md](./dependency_management.md) | Poetry dependency standards |
| [cli_command_surface.md](./cli_command_surface.md) | Explicit Click command matrix and no-passthrough policy |
| [aws_integration_environment_doctrine.md](./aws_integration_environment_doctrine.md) | Host-level AWS CLI auth plus real AWS integration environment creation, tagging, and cleanup doctrine |
| [distributed_gateway_architecture.md](./distributed_gateway_architecture.md) | Multi-node gateway leadership and failover design |
| [effectful_dag_architecture.md](./effectful_dag_architecture.md) | Effect DAG system design |
| [effect_interpreter.md](./effect_interpreter.md) | Interpreter runtime execution contract |
| [integration_fixture_doctrine.md](./integration_fixture_doctrine.md) | Cluster-backed pytest setup/teardown doctrine |
| [local_registry_pipeline.md](./local_registry_pipeline.md) | Harbor installation + local image mirror pipeline |
| [storage_lifecycle_doctrine.md](./storage_lifecycle_doctrine.md) | Retained storage + deterministic PVC/PV rebinding doctrine |
| [prerequisite_doctrine.md](./prerequisite_doctrine.md) | Fail-fast prerequisite philosophy |
| [prerequisite_dag_system.md](./prerequisite_dag_system.md) | Prerequisite DAG construction and runtime reference |
| [streaming_doctrine.md](./streaming_doctrine.md) | Streaming and terminal-record serialization invariants |
| [tla/README.md](./tla/README.md) | TLA+ model index for formal safety properties |
| [tla_modelling_assumptions.md](./tla_modelling_assumptions.md) | TLA+ formal model correspondence, divergences, and verification status |
| [unit_testing_policy.md](./unit_testing_policy.md) | Interpreter-Only Mocking Doctrine |
| [pure_fp_standards.md](./pure_fp_standards.md) | Pure FP coding standards |
| [code_quality.md](./code_quality.md) | Policy guardrails and check-code gate |
| [refactoring_patterns.md](./refactoring_patterns.md) | Imperative to pure FP migration patterns |
| [helm_chart_platform_doctrine.md](./helm_chart_platform_doctrine.md) | Singleton chart identity, namespace isolation, storage lifecycle, and delete semantics for `prodbox charts` |

---

## Quick Navigation

### Effect DAG System
- [Effect Types](./effectful_dag_architecture.md#3-effect-types)
- [DAG Construction](./effectful_dag_architecture.md#4-dag-construction)
- [Interpreter Pattern](./effectful_dag_architecture.md#5-interpreter-pattern)
- [Interpreter Runtime Contract](./effect_interpreter.md#1-runtime-parity-statement)
- [Streaming Contract](./streaming_doctrine.md#1-streaming-contract-statement)
- [Terminal Record Contract](./streaming_doctrine.md#5-terminal-record-contract)

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
- [AWS Test Environment](./aws_test_environment.md)
- [AWS Integration Environment Doctrine](./aws_integration_environment_doctrine.md)
- [Integration Fixture Doctrine](./integration_fixture_doctrine.md)
- [Forbidden Patterns](./unit_testing_policy.md#3-forbidden-patterns)
- [Allowed Patterns](./unit_testing_policy.md#4-allowed-patterns)
- [Two-Phase Test Command Doctrine](./unit_testing_policy.md#two-phase-test-command-doctrine)
- [Phase Banner Rendering Contract](./unit_testing_policy.md#phase-banner-rendering-contract)

### Code Quality
- [Code Quality Doctrine](./code_quality.md)
- [Pure FP Standards](./pure_fp_standards.md)

### CLI Surface
- [CLI Command Surface](./cli_command_surface.md)
- [Unit Testing Policy](./unit_testing_policy.md#two-phase-test-command-doctrine)

### Chart Platform
- [Helm Chart Platform Doctrine](./helm_chart_platform_doctrine.md)
- [Chart Storage Contract](./helm_chart_platform_doctrine.md#7-datanamespacestatefulsetordinal-host-path-contract)
- [Delete Semantics](./helm_chart_platform_doctrine.md#8-delete-semantics)
- [Repo-Local Storage](./storage_lifecycle_doctrine.md#7-repo-local-data-chart-storage)
- Supported `vscode` path: cluster-backed `prodbox charts` only

---

## Intent Ownership

This index co-owns documentation-topology doctrine intention.

- Owned statement: SSoT ownership, bidirectional links, and non-duplication rules are mandatory for all new doctrinal content.
- Linked dependents: [Documentation Standards](../documentation_standards.md), [Code Quality Doctrine](./code_quality.md).

---

## Cross-References

- [Development Plan](../../DEVELOPMENT_PLAN/README.md)
- [Documentation Standards](../documentation_standards.md)
- [CLAUDE.md](../../CLAUDE.md)
- [AGENTS.md](../../AGENTS.md)
