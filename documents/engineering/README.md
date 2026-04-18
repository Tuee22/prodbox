# Engineering Documentation

**Status**: Reference only
**Supersedes**: N/A
**Referenced by**: README.md, DEVELOPMENT_PLAN/README.md, DEVELOPMENT_PLAN/00-overview.md, documents/documentation_standards.md, documents/engineering/aws_test_environment.md

> **Purpose**: Index of engineering and architecture documentation.

SSoT ownership, bidirectional links, and non-duplication rules are mandatory for all new doctrinal
content.

## Roadmap

Clean-room build order, sprint status, blockers, validation closure, and cleanup ownership are
tracked only in [DEVELOPMENT_PLAN/README.md](../../DEVELOPMENT_PLAN/README.md).

The documents in this directory are stable doctrine and architecture references. They describe the
current Haskell-only repository contract rather than a mixed migration baseline.

## Documents

| Document | Purpose |
|----------|---------|
| [aws_account_setup_guide.md](./aws_account_setup_guide.md) | AWS account creation, hosted-zone preparation, and temporary elevated-key workflow for `prodbox config setup` |
| [aws_admin_credentials.md](./aws_admin_credentials.md) | Test-only elevated `aws_admin` credential harness and lifecycle guidance |
| [aws_test_environment.md](./aws_test_environment.md) | Shared AWS member-account, DNS, isolation, lifecycle, and auth doctrine for ephemeral multi-project testing |
| [acme_provider_guide.md](./acme_provider_guide.md) | ZeroSSL vs Let's Encrypt guidance for the interactive onboarding flow |
| [dependency_management.md](./dependency_management.md) | Cabal- and toolchain-level dependency doctrine |
| [cli_command_surface.md](./cli_command_surface.md) | Canonical operator command matrix |
| [aws_integration_environment_doctrine.md](./aws_integration_environment_doctrine.md) | Real AWS integration environment creation, tagging, and cleanup doctrine |
| [distributed_gateway_architecture.md](./distributed_gateway_architecture.md) | Multi-node gateway leadership and failover design |
| [effectful_dag_architecture.md](./effectful_dag_architecture.md) | Effect DAG system design |
| [effect_interpreter.md](./effect_interpreter.md) | Interpreter runtime execution contract |
| [integration_fixture_doctrine.md](./integration_fixture_doctrine.md) | Cluster-backed integration setup and teardown doctrine |
| [local_registry_pipeline.md](./local_registry_pipeline.md) | Harbor installation plus local image mirror pipeline |
| [storage_lifecycle_doctrine.md](./storage_lifecycle_doctrine.md) | Retained storage and deterministic PVC/PV rebinding doctrine |
| [prerequisite_doctrine.md](./prerequisite_doctrine.md) | Fail-fast prerequisite philosophy and registry doctrine |
| [prerequisite_dag_system.md](./prerequisite_dag_system.md) | Prerequisite DAG construction and reduction reference |
| [streaming_doctrine.md](./streaming_doctrine.md) | Streaming and terminal-record serialization invariants |
| [tla/README.md](./tla/README.md) | TLA+ model index for formal safety properties |
| [tla_modelling_assumptions.md](./tla_modelling_assumptions.md) | TLA+ formal model correspondence, divergences, and verification status |
| [unit_testing_policy.md](./unit_testing_policy.md) | Test-runner doctrine and validation contract |
| [pure_fp_standards.md](./pure_fp_standards.md) | Pure FP coding standards |
| [code_quality.md](./code_quality.md) | Policy guardrails and the `check-code` gate |
| [refactoring_patterns.md](./refactoring_patterns.md) | Imperative to pure FP migration patterns |
| [helm_chart_platform_doctrine.md](./helm_chart_platform_doctrine.md) | Singleton chart identity, namespace isolation, storage lifecycle, and delete semantics for `prodbox charts` |

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

- [Lock File Policy](./dependency_management.md#2-lock-file-policy)
- [Version Constraint Standards](./dependency_management.md#3-version-constraint-standards)

### Unit Testing

- [AWS Account Setup Guide](./aws_account_setup_guide.md)
- [AWS Admin Credentials](./aws_admin_credentials.md)
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

- [AWS Account Setup Guide](./aws_account_setup_guide.md)
- [ACME Provider Guide](./acme_provider_guide.md)
- [AWS Admin Credentials](./aws_admin_credentials.md)
- [CLI Command Surface](./cli_command_surface.md)
- [Unit Testing Policy](./unit_testing_policy.md#two-phase-test-command-doctrine)

### Chart Platform

- [Helm Chart Platform Doctrine](./helm_chart_platform_doctrine.md)
- [Chart Storage Contract](./helm_chart_platform_doctrine.md#7-datanamespacereleaseworkloadordinalclaim-host-path-contract)
- [Delete Semantics](./helm_chart_platform_doctrine.md#8-delete-semantics)
- [Repo-Local Storage](./storage_lifecycle_doctrine.md#7-repo-local-retained-state-layout)
- Supported `vscode` path: cluster-backed `prodbox charts` only

## Intent Ownership

This index co-owns documentation-topology doctrine intention.

- Owned statement: SSoT ownership, bidirectional links, and non-duplication rules are mandatory
  for all new doctrinal content.
- Linked dependents: [Documentation Standards](../documentation_standards.md), [Code Quality Doctrine](./code_quality.md).

## Cross-References

- [Development Plan](../../DEVELOPMENT_PLAN/README.md)
- [Documentation Standards](../documentation_standards.md)
- [CLAUDE.md](../../CLAUDE.md)
- [AGENTS.md](../../AGENTS.md)
