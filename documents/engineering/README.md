# Engineering Documentation

**Status**: Reference only
**Supersedes**: Pre-refactor distributed doctrine index
**Generated sections**: none
**Applicability**: Navigation for adopted target contracts

> **Purpose**: Point to the single owner of each architecture decision and the numerical implementation plan.

The Markdown contracts adopt the kind-based refactor. Runtime code is unchanged in this documentation-only session; the installed binary and [current generated command reference](../cli/commands.md) still describe the RKE2-era surface. Checker/code migration is open in Phase 0. Read [Resume Here](../../DEVELOPMENT_PLAN/README.md#resume-here) for the only execution queue.

| Contract | Owner |
|---|---|
| Product objectives, roles and local/EKS shape | [Product architecture](product_architecture.md) |
| Target CLI, visibility, command outcomes and remedies | [CLI command surface](cli_command_surface.md) |
| One journal/engine, resource observations, complete AWS delete | [Lifecycle](lifecycle.md) |
| kind bootstrap, physical dependencies and management recovery | [Control plane](control_plane.md) |
| `.data`/`.test-data`, mounts, PV/EBS, backup and destruction | [Storage](storage.md) |
| Dhall, explicit contexts, authored spec and capability prerequisites | [Configuration](configuration.md) |
| Vault/unlock, ephemeral elevated input, operational credentials and redaction | [Security and credentials](security_and_credentials.md) |
| Canonical microservices, charts, registry and substrate adapters | [Platform and services](platform_and_services.md) |
| DNS/ZeroSSL/Envoy, real auth/email/invitation | [Public edge](public_edge.md) |
| Exact AWS families, SES isolation, quotas and provider evidence | [AWS resources](aws_resources.md) |
| Gateway convergence/HA, emitter continuity, CBOR/Pulsar/topics | [Gateway and messaging](gateway_and_messaging.md) |
| Explicit child trust/custody/recovery | [Federation](federation.md) |
| Real phase evidence, isolated harness, negative controls and source mutants | [Testing](testing.md) |
| Finite CPU/memory/storage/concurrency, measurement and scaling | [Resource governance](resource_governance.md) |
| Haskell types, effects, errors, subprocesses and concurrency | [Haskell code guide](haskell_code_guide.md) |
| Canonical quality gate and generated/document checks | [Code quality](code_quality.md) |
| Toolchain/runtime pins, artifacts and upgrades | [Dependency management](dependency_management.md) |

[Documentation standards](../documentation_standards.md) govern ownership/headers/links. [Objectives](../../DEVELOPMENT_PLAN/objective_dispositions.md), [command dispositions](../../DEVELOPMENT_PLAN/command_dispositions.md), [acceptance cases](../../DEVELOPMENT_PLAN/acceptance_cases.md), [mutation cases](../../DEVELOPMENT_PLAN/mutation_cases.md) and the [deletion ledger](../../DEVELOPMENT_PLAN/legacy_tracking_for_deletion.md) make the adopted plan reviewable. Engineering docs do not publish a competing work queue or current proof status.

Old doctrine paths may remain short deprecated forwarding references while code/checker links are migrated. Their original text is historical evidence, not another active target. Do not revive its RKE2 placement, cascade semantics, shared test/production SES or component-only Done model.
