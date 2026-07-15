# Engineering Documentation

**Status**: Reference only
**Supersedes**: N/A
**Referenced by**: README.md, CLAUDE.md, DEVELOPMENT_PLAN/README.md, DEVELOPMENT_PLAN/00-overview.md, documents/documentation_standards.md, documents/engineering/aws_test_environment.md
**Generated sections**: none

> **Purpose**: Index of engineering and architecture documentation.

SSoT ownership, bidirectional links, and non-duplication rules are mandatory for all new doctrinal
content.

## Roadmap

Clean-room build order, sprint status, blockers, validation closure, and cleanup ownership are
tracked only in [DEVELOPMENT_PLAN/README.md](../../DEVELOPMENT_PLAN/README.md).

The documents in this directory are stable doctrine and architecture references. A document may
define a target before cutover only when it says so explicitly and delegates implementation and
qualification status to the Development Plan. Current-behavior doctrine must continue to describe
the implemented repository state; it may not silently promote a planned topology into a supported
one.

Pulumi doctrine in this directory applies only to the AWS substrate stacks under
`pulumi/aws-eks/`, `pulumi/aws-eks-subzone/`, `pulumi/aws-test/`, and `pulumi/aws-ses/`. Of those,
`aws-eks`, `aws-eks-subzone`, and `aws-test` are per-run stacks; `aws-ses` is long-lived
cross-substrate shared infrastructure (see
[../../DEVELOPMENT_PLAN/substrates.md → Resource Lifecycle Classes](../../DEVELOPMENT_PLAN/substrates.md#resource-lifecycle-classes)).

## Documents

| Document | Purpose |
|----------|---------|
| [aws_account_setup_guide.md](./aws_account_setup_guide.md) | AWS account creation, hosted-zone preparation, and prompt-driven temporary admin-key workflow for `prodbox config setup` |
| [aws_admin_credentials.md](./aws_admin_credentials.md) | `aws_admin_for_test_simulation` test-secrets.dhall test-harness fixture and the prompt-based admin-credential lifecycle |
| [aws_test_environment.md](./aws_test_environment.md) | Shared AWS member-account, DNS, isolation, lifecycle, and auth doctrine for ephemeral multi-project testing |
| [acme_provider_guide.md](./acme_provider_guide.md) | ZeroSSL ACME guidance for the interactive onboarding flow, and the configurable `CertScopeSet` certificate-scope model — exact and wildcard scopes, coverage/narrowing semantics, and the edge projections derived from the one scope set |
| [chaos_hardening_doctrine.md](./chaos_hardening_doctrine.md) | Concurrency-hardening treatise & doctrine: the Extract → Model → Inject moves over the decision/protocol/runtime layers, the TLA+ and chaos-engineering traditions, the consistency-boundary second axis, and the proven/tested/assumed ledger |
| [dependency_management.md](./dependency_management.md) | Cabal/toolchain dependency doctrine, including executable-only RTS parsing for generated heap policy without hard-coded caps |
| [cli_command_surface.md](./cli_command_surface.md) | Canonical operator command matrix |
| [config_doctrine.md](./config_doctrine.md) | The canonical three-tier config model (§0: Tier 0 self-contained non-secret bootstrap context; Tier 1 password-gated recovery material; Tier 2 Vault-gated operational secrets/state), the Lifecycle Authority generation/reference that selects an immutable encrypted config blob, generated/local-only Dhall rules, mount/reload contracts, and forbidden config surfaces |
| [aws_integration_environment_doctrine.md](./aws_integration_environment_doctrine.md) | Real AWS integration environment creation, tagging, and cleanup doctrine |
| [distributed_gateway_architecture.md](./distributed_gateway_architecture.md) | Multi-node gateway leadership/failover doctrine: bounded mesh state, a single-writer emitter journal, credential-gated DNS, and constant-time lifecycle projections; lifecycle/bootstrap authority is explicitly outside the gateway |
| [lifecycle_control_plane_architecture.md](./lifecycle_control_plane_architecture.md) | Pure-functional physical topology for Bootstrap Broker, Lifecycle Authority, private Backup/TLS adapters and Provider/Credential/Admin workers, substrate Target Agents, capability-indexed programs, authority cutover/repair, independent failure/resource domains, the compiled service boundary, durability-indexed retained custody, and measured-capacity certification of authored envelopes, plus the §5.4/§5.5 TLS custody closure — public-edge retention re-keyed to a canonical scope-set serialization, certificate private keys excluded from the closed retained-material schema |
| [envoy_gateway_edge_doctrine.md](./envoy_gateway_edge_doctrine.md) | Canonical MetalLB + Envoy Gateway + Keycloak public-edge doctrine, including JWT, Redis, and WebSocket boundaries; served hostnames are total projections of the configured certificate scope set, with wildcard public DNS supported when anchored at a config-declared delegated zone |
| [effectful_dag_architecture.md](./effectful_dag_architecture.md) | Effect DAG system design |
| [effect_interpreter.md](./effect_interpreter.md) | Interpreter runtime execution contract |
| [haskell_code_guide.md](./haskell_code_guide.md) | Hard-gate Haskell quality doctrine, review-guidance split, and the landed opaque runtime-memory/generated RTS boundary |
| [integration_fixture_doctrine.md](./integration_fixture_doctrine.md) | Cluster-backed integration setup and teardown doctrine |
| [lifecycle_reconciliation_doctrine.md](./lifecycle_reconciliation_doctrine.md) | Reconciler-with-predicates pattern for desired absence/presence, managed-resource classes, durable lifecycle operations, authority fencing, immutable checkpoint references, target-delivery outbox, always-run cleanup semantics, the derived restore/cleanup graph with total executor, and the per-run-only harness residue bypass |
| [local_registry_pipeline.md](./local_registry_pipeline.md) | In-cluster registry (registry:2) workload sourcing, public-image reconcile, and native-host-architecture image publication |
| [storage_lifecycle_doctrine.md](./storage_lifecycle_doctrine.md) | Unified block-storage doctrine: static `Retain` no-provisioner PVs on both substrates (home `hostPath`, EKS pre-created EBS) and deterministic PVC/PV rebinding |
| [prerequisite_doctrine.md](./prerequisite_doctrine.md) | Fail-fast prerequisite philosophy and registry doctrine |
| [prerequisite_dag_system.md](./prerequisite_dag_system.md) | Prerequisite DAG construction and reduction reference |
| [bootstrap_readiness_doctrine.md](./bootstrap_readiness_doctrine.md) | Capability-indexed dependency barriers whose observation, admission, and execution share one exact reference; distinguishes process health, operational admission, capability evidence, and temporal stability |
| [streaming_doctrine.md](./streaming_doctrine.md) | Streaming and terminal-record serialization invariants |
| [tla/README.md](./tla/README.md) | TLA+ model index for formal safety properties |
| [tla_modelling_assumptions.md](./tla_modelling_assumptions.md) | TLA+ formal model correspondence, divergences, and verification status |
| [unit_testing_policy.md](./unit_testing_policy.md) | Test-runner doctrine, validation contract, and the seconds-fast pre-cluster conformance tier for cross-artifact agreement |
| [pure_fp_standards.md](./pure_fp_standards.md) | Pure FP coding standards for closed operation-indexed programs, opaque capability references, total external-state folds, explicit interpreters, proof values kept separate from observations, the one-typed-model/many-generated-projections rule, and durability-indexed coordinates |
| [code_quality.md](./code_quality.md) | Policy guardrails and the `prodbox dev check` doctrine-alignment gate, including the conformance-tier check families (forbidden-literal chart lint, legacy escape-registry bijection, measured-profile certification) |
| [refactoring_patterns.md](./refactoring_patterns.md) | Imperative to pure FP migration patterns |
| [helm_chart_platform_doctrine.md](./helm_chart_platform_doctrine.md) | Singleton chart identity, namespace isolation, storage/delete lifecycle, constant-time gateway probe-binding contract, and the probe/route single-source rule for `prodbox charts` |
| [secret_derivation_doctrine.md](./secret_derivation_doctrine.md) | Vault-only secret storage and the host↔cluster access boundary; the filename is retained for link stability after retirement of master-seed derivation and gateway secret-service RPCs |
| [vault_doctrine.md](./vault_doctrine.md) | Vault as the fail-closed secrets / KMS / PKI backend: the SecretRef contract, MinIO-resident password-AEAD unlock bundle, Bootstrap Broker boundary, dedicated authority/target-agent policies, Transit envelope encryption, sealed-state invariant, and Kubernetes auth |
| [cluster_federation_doctrine.md](./cluster_federation_doctrine.md) | Cluster federation: the root/child Vault transit-seal trust tree, parent custody of child recovery material, downstream-cluster metadata as secret, generation-CAS config authority, and the fail-closed unseal cascade; child-cluster public-edge TLS is per-zone self-issuance with delivered `AcmeEabMaterial` (a parent never hands a child certificate private-key material) |
| [pulsar_messaging_doctrine.md](./pulsar_messaging_doctrine.md) | Self-maintained native-protocol Pulsar client and the project-wide CBOR-always payload rule (no codec-selection field — non-CBOR payloads unrepresentable), the derived `topicFor` topic algebra, and the `Work*` envelope family |
| [resource_scaling_doctrine.md](./resource_scaling_doctrine.md) | Resource governor separating admission/containment from runtime demand: memory algebra, CPU service-rate and queue/deadline proofs, independent control-plane envelopes, temporal stability evidence, substrate-indexed scaling, price/quota gates, and measured resource profiles certifying authored envelopes |
| [pulsar_topic_lifecycle_doctrine.md](./pulsar_topic_lifecycle_doctrine.md) | Pulsar topics as first-class managed resources — typed three-valued broker discover, typed idempotent destroy, and a lifecycle class reconciled through the §3.1 registry; names from the topic algebra, retention drawn from the finite storage budget |
| [tiered_storage_capacity_doctrine.md](./tiered_storage_capacity_doctrine.md) | Finite-budget durable-storage capacity DSL: no `Infinite` constructor, sizeless-claim and over-quota unrepresentable, MinIO "unlimited" only with an autoscaling witness, AWS region service-quota as the real cloud ceiling, mandatory ML JIT + model-cache budgets, and no durable-destruction primitive |
| [host_platform_doctrine.md](./host_platform_doctrine.md) | Per-OS host-provider model mirrored in kind from hostbootstrap: the detected `HostSubstrate`, the closed `HostTool` enum, and the `LiftLayer` provider fold (Lima on Apple, WSL2 on Windows, Incus/native on Linux) with "everything Docker-inward is OS-agnostic Linux"; makes rke2-without-a-VM (Apple/Windows) and host-frame `docker` on Windows unrepresentable |
| [cluster_topology_doctrine.md](./cluster_topology_doctrine.md) | The three explicit cluster types (`kind`/`rke2`/`eks`, never inferred), the substrate-indexed one-compute-worker-per-machine rule, and the type shapes that make ill-formed topologies (multi-node rke2 on one machine, cross-machine kind, wrong-substrate worker, mixed-substrate kind/eks) unrepresentable |
| [test_topology_doctrine.md](./test_topology_doctrine.md) | The executable-sibling `prodbox.test.dhall` SSoT, `.test-data/` isolation, per-run teardown, and the rule that retaining long-lived resources during cleanup does not exclude capability-derived desired-present preparation |

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
- [Lifecycle Control-Plane Boundary](./lifecycle_control_plane_architecture.md)
- [Compiled Service Boundary](./lifecycle_control_plane_architecture.md#102-compiled-service-boundary)
- [Bounded Semantic State and Delta Replication](./distributed_gateway_architecture.md#72-bounded-delta-replication)
- [Runtime Memory Contract](./distributed_gateway_architecture.md#123-runtime-memory-contract)
- [Public Edge Doctrine](./envoy_gateway_edge_doctrine.md)
- [Local Registry Pipeline](./local_registry_pipeline.md)
- [Gateway Container Build Doctrine](./local_registry_pipeline.md#6-gateway-container-build-doctrine)
- [Storage Lifecycle Doctrine](./storage_lifecycle_doctrine.md)
- [TLA+ Models](./tla/README.md)
- [TLA+ Modelling Assumptions](./tla_modelling_assumptions.md)

### Public Edge

- [Envoy Gateway Edge Doctrine](./envoy_gateway_edge_doctrine.md)
- [Authentication Doctrine](./envoy_gateway_edge_doctrine.md#5-authentication-doctrine)
- [JWT Validation Doctrine](./envoy_gateway_edge_doctrine.md#6-jwt-validation-doctrine)
- [Redis and WebSocket Doctrine](./envoy_gateway_edge_doctrine.md#7-redis-and-websocket-doctrine)
- [Scaling and Availability Doctrine](./envoy_gateway_edge_doctrine.md#8-scaling-and-availability-doctrine)
- [Operational and Delivery Implications](./envoy_gateway_edge_doctrine.md#9-operational-and-delivery-implications)
- [Recommended Migration and Adoption Path](./envoy_gateway_edge_doctrine.md#10-recommended-migration-and-adoption-path)
- [Diagnostics and Validation Doctrine](./envoy_gateway_edge_doctrine.md#11-diagnostics-and-validation-doctrine)
- [ACME Provider Guide](./acme_provider_guide.md)
- [ZeroSSL](./acme_provider_guide.md#2-zerossl)
- [CLI Command Surface](./cli_command_surface.md)
- [Helm Chart Platform Doctrine](./helm_chart_platform_doctrine.md)
- [Local Registry Pipeline](./local_registry_pipeline.md)
- [Unit Testing Policy](./unit_testing_policy.md)

### Prerequisites

- [Fail-Fast Philosophy](./prerequisite_doctrine.md#1-philosophy)
- [Prerequisite Registry](./prerequisite_doctrine.md#3-registry)
- [Prerequisite DAG System](./prerequisite_dag_system.md)
- [Bootstrap Readiness Doctrine](./bootstrap_readiness_doctrine.md)
- [Capability and Authority Topology](./lifecycle_control_plane_architecture.md)
- [Shallow-Gate Invariant](./bootstrap_readiness_doctrine.md#0-canonical-doctrine-statements)
- [Dependency Readiness vs Runtime Stability](./bootstrap_readiness_doctrine.md#24-dependency-readiness-vs-runtime-stability)

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
- [The Conformance Tier](./unit_testing_policy.md#the-conformance-tier)
- [Two-Phase Test Command Doctrine](./unit_testing_policy.md#two-phase-test-command-doctrine)
- [Phase Banner Rendering Contract](./unit_testing_policy.md#phase-banner-rendering-contract)

### Code Quality

- [Code Quality Doctrine](./code_quality.md)
- [Haskell Code Guide](./haskell_code_guide.md)
- [Pure FP Standards](./pure_fp_standards.md)
- [One Typed Model, Many Generated Projections](./pure_fp_standards.md#14-one-typed-model-many-generated-projections)
- [Durability-Indexed Coordinates](./pure_fp_standards.md#24-durability-indexed-coordinates)

### CLI Surface

- [AWS Account Setup Guide](./aws_account_setup_guide.md)
- [ACME Provider Guide](./acme_provider_guide.md)
- [AWS Admin Credentials](./aws_admin_credentials.md)
- [CLI Command Surface](./cli_command_surface.md)
- [Unit Testing Policy](./unit_testing_policy.md#two-phase-test-command-doctrine)

### Chart Platform

- [Helm Chart Platform Doctrine](./helm_chart_platform_doctrine.md)
- [Chart Storage Contract](./helm_chart_platform_doctrine.md#6-datanamespacestatefulsetordinal-host-path-contract)
- [Delete Semantics](./helm_chart_platform_doctrine.md#8-delete-semantics)
- [Probe and Route Single-Source Rule](./helm_chart_platform_doctrine.md#probe-and-route-single-source-rule)
- [Supported Public Auth Model (public-edge production TLS retention)](./helm_chart_platform_doctrine.md#9-supported-public-auth-model)
- [ACME Provider Guide](./acme_provider_guide.md)
- [Managed-Resource Registry (production-cert LongLived registration)](./lifecycle_reconciliation_doctrine.md#31-the-managed-resource-registry-the-reconciler-substrate)
- [Derived Restore/Cleanup Graph and Total Executor](./lifecycle_reconciliation_doctrine.md#33-the-derived-restorecleanup-graph-and-total-executor)
- [Repo-Local Storage](./storage_lifecycle_doctrine.md#7-repo-local-retained-state-layout)
- Supported `vscode` path: cluster-backed `prodbox charts` only

### Resource Governance

- [Resource Scaling Doctrine](./resource_scaling_doctrine.md)
- [Mandatory Resource Requirements](./resource_scaling_doctrine.md#2a-resource-requirements-are-mandatory-and-capped)
- [Host, RKE2, Cluster, Namespace, and Pod Lemmas](./resource_scaling_doctrine.md#2b-host-rke2-cluster-namespace-and-pod-lemmas)
- [Runtime Memory Decomposition and Observation](./resource_scaling_doctrine.md#2d-runtime-memory-decomposition-and-observation)
- [Measured Resource Profiles](./resource_scaling_doctrine.md#2f-measured-resource-profiles)
- [Tiered Storage Capacity Doctrine](./tiered_storage_capacity_doctrine.md)

### Secrets and Vault

- [Vault Secret-Management Doctrine](./vault_doctrine.md)
- [SecretRef model](./vault_doctrine.md#3-the-secretref-model)
- [Unlock bundle (root cluster, MinIO-resident, password-AEAD)](./vault_doctrine.md#6-the-unlock-bundle-root-cluster)
- [Bootstrap MinIO credential](./vault_doctrine.md#61-bootstrap-minio-credential)
- [Envelope encryption with Vault Transit](./vault_doctrine.md#8-envelope-encryption-with-vault-transit)
- [Sealed-state behavior matrix](./vault_doctrine.md#15-sealed-state-behavior-matrix)
- [Cluster Federation Doctrine](./cluster_federation_doctrine.md)
- [Transit-seal trust tree](./cluster_federation_doctrine.md#2-the-transit-seal-trust-tree)
- [Fail-closed unseal cascade](./cluster_federation_doctrine.md#7-the-fail-closed-unseal-cascade)
- [Three-Tier Config Model](./config_doctrine.md#0-three-tier-config-model)
- [Config Doctrine (SecretRef contract)](./config_doctrine.md)
- [Secret Derivation Doctrine](./secret_derivation_doctrine.md)
- [Storage Lifecycle (Vault PV preservation)](./storage_lifecycle_doctrine.md)

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
