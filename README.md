# Prodbox

**Status**: Reference only
**Supersedes**: N/A
**Generated sections**: none
**Applicability**: Project navigation and accepted target overview; runtime migration is still open.

> **Purpose**: Introduce the product, distinguish accepted design from current implementation, and lead contributors to one executable development plan.

Prodbox is a Haskell CLI for operating a retained local Kubernetes management plane and the same application/platform services locally or on AWS. The accepted refactor uses local **kind** for Vault, MinIO, lifecycle management and recovery, with EKS as an optional application target.

## Start here

- To implement the refactor, read [AGENTS.md](AGENTS.md), then [DEVELOPMENT_PLAN/README.md → Resume Here](DEVELOPMENT_PLAN/README.md#resume-here). Work open phases in numerical order.
- For architecture, use the [engineering index](documents/engineering/README.md) and [product architecture](documents/engineering/product_architecture.md).
- For target commands, use the [CLI contract](documents/engineering/cli_command_surface.md). For commands actually installed today, inspect the binary's help and [generated current reference](documents/cli/commands.md).
- For accepted documentation rules and closure, use [Documentation Standards](documents/documentation_standards.md) and [Development Plan Standards](DEVELOPMENT_PLAN/development_plan_standards.md).
- For obsolete routes and their removal owners, use [the legacy ledger](DEVELOPMENT_PLAN/legacy_tracking_for_deletion.md).

## Accepted operating model

The management plane stays available while applications are reconciled or deleted. It contains the existing Bootstrap Broker, Vault, MinIO, Lifecycle Authority, Provider Worker, Credential Provisioner, Backup/TLS adapters and Target Secret Agent roles. Canonical application services remain gateway, Keycloak/PostgreSQL, VS Code, API, Redis, websocket and their platform/messaging dependencies.

The target everyday workflow is configuration, control reconciliation, application reconciliation, status, and deletion. Ordinary target `prodbox delete --yes` removes all deployment-owned AWS resources and updates retained local state. It retains the kind management plane. Control-cluster removal and destructive local-data purge are separate operations; `--cascade` is retired.

Production `.data/` and testing `.test-data/` have separate identities, mounts, clusters, endpoints, credentials and cloud ownership. Test SES resources are separate from production; a campaign may reuse its own resources across cases. Explicit deletion removes that campaign/deployment's owned AWS scope, including formerly retained SES, EBS, state stores and generated IAM identities.

`test-secrets.dhall` continues to simulate the operator's ephemeral elevated AWS prompt through the real credential workflow. Generated operational material lives in Vault. Test-only MinIO self-unseal permits unattended test recovery; production uses protected custody or requests input.

These contracts are adopted in documentation. They do not assert that the current binary already implements them. The current code still has RKE2-era command and lifecycle behavior. Phase 0 remains open for checker/tooling adoption, and later phases activate the public replacement slices as each one is actually validated.

## Build the current binary

Use the repository's pinned Cabal/Haskell toolchain:

```bash
cabal build --builddir=.build exe:prodbox
mkdir -p .build
cp "$(cabal list-bin --builddir=.build exe:prodbox)" .build/prodbox
chmod +x .build/prodbox
./.build/prodbox --help
```

The current canonical quality entrypoint is:

```bash
./.build/prodbox dev check
```

The Markdown adoption intentionally leaves code unchanged. The old documentation checker still encodes superseded plan paths and sprint grammar; Phase 0 must migrate its checks and prove their failures before the new plan can claim that gate passes. Do not interpret a structure-only document check as runtime validation.

## Development outcome

A completed phase demonstrates its public behavior using actual earlier capabilities, independent observations, adverse/resume cases, targeted source mutation tests, exact cleanup and owned legacy removal. There is no completion badge for locally sound fragments whose required composed behavior remains deferred.

The final phase repeats earlier real journeys and validates existing-install migration; it is not the first activation of a replacement accumulated privately over prior phases. [Objective dispositions](DEVELOPMENT_PLAN/objective_dispositions.md) and [command dispositions](DEVELOPMENT_PLAN/command_dispositions.md) prevent product features from disappearing during simplification.

## Repository layout

```text
app/                 Haskell executable
src/Prodbox/         CLI, runtime, lifecycle, resources and interpreters
test/                Haskell tests and acceptance support
docker/              Canonical container builds
prodbox.cabal        Package definition
cabal.project        Project configuration
documents/           Accepted contracts, operator material and reference
DEVELOPMENT_PLAN/    Numerical implementation queue and evidence ownership
```

[History navigation](documents/history/README.md) preserves access to superseded plans and evidence without keeping them in the active queue. No runtime or infrastructure reset follows merely from updating these documents.
