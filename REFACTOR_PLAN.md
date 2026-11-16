# Adopted CLI and Lifecycle Refactor

**Status**: Reference only
**Supersedes**: The proposal preserved in `documents/history/refactor_proposal_2026_11.md`
**Generated sections**: none
**Applicability**: Navigation for the adopted documentation contract; code and infrastructure were not refactored by adoption.

> **Purpose**: Point a fresh implementation session to the accepted architecture and numerical development phases.

The requested Markdown refactor has adopted the design into the canonical documents below. This file is no longer a second architecture document or execution queue. The [original reviewed proposal](documents/history/refactor_proposal_2026_11.md) is historical evidence only.

## Start implementation

Read [DEVELOPMENT_PLAN/README.md → Resume Here](DEVELOPMENT_PLAN/README.md#resume-here), then work its first incomplete phase in numerical order. **Phase 0 remains open for the code-side checker/registry adoption and actual acceptance/mutation proof.** Markdown adoption alone does not satisfy it. Do not resume the former decimal-sprint queue.

The current binary still implements the older topology. Target commands are not advertised as already installed. The next session first migrates old hardcoded document/phase/ledger checks without weakening substantive checks, then implements subsequent public slices.

## Canonical contracts

- [Product architecture](documents/engineering/product_architecture.md), [CLI structure](documents/engineering/cli_command_surface.md), and [lifecycle](documents/engineering/lifecycle.md): retained local kind Authority; ordinary delete removes the selected deployment's owned AWS resources, without `--cascade` or local control removal.
- [Storage](documents/engineering/storage.md), [configuration](documents/engineering/configuration.md), and [security](documents/engineering/security_and_credentials.md): isolated `.data/` and `.test-data/`, ephemeral elevated operator/test credential ingress, protected production unlock and test-only MinIO self-unseal.
- [Documentation standards](documents/documentation_standards.md) and [development plan standards](DEVELOPMENT_PLAN/development_plan_standards.md): one owner per decision, strictly ordered real phase validation, targeted mutations and complete removal obligations.
- [Feature dispositions](DEVELOPMENT_PLAN/objective_dispositions.md), [all command/option dispositions](DEVELOPMENT_PLAN/command_dispositions.md), [acceptance cases](DEVELOPMENT_PLAN/acceptance_cases.md), [mutation cases](DEVELOPMENT_PLAN/mutation_cases.md), and [legacy removals](DEVELOPMENT_PLAN/legacy_tracking_for_deletion.md): complete Markdown inventories for implementation.

Test SES identities, SMTP credentials, capture/DNS resources and owned receipt rules are separate from production. Campaign-local reuse is permitted; cleanup cannot disrupt another scope's active receiving rules.

This adoption edits only Markdown. It does not mutate infrastructure, generated schemas, code, test fixtures, source models, or existing retained storage. Historical forwarding docs remain only until Phase 0 migrates code-side references and retires them.
