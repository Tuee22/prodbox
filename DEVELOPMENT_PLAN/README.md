# Prodbox Development Plan

**Status**: Authoritative source
**Supersedes**: The pre-refactor fractional-sprint execution queue
**Generated sections**: none
**Applicability**: Current implementation queue for the adopted kind/CLI refactor; runtime implementation remains open.

> **Purpose**: Give a fresh agent one numerical route from the current Haskell implementation to the accepted product.

## Resume Here

Read [AGENTS.md](../AGENTS.md), the [Development Plan Standards](development_plan_standards.md), and the first incomplete phase below. Implement open phases in numerical order. Every phase validates its real predecessors and owns its public activation, cleanup and legacy removals. Do not resume the superseded fractional-sprint queue.

| Phase | Contract | State | Next work / entry condition |
|---:|---|---|---|
| 0 | [Contracts and documentation](phase_00_contracts_and_documentation.md) | Complete | Checker, negative fixtures, M00 and owned removals validated; see [evidence](evidence/phase_00_validation.md). |
| 1 | [CLI contexts, kind and evidence](phase_01_cli_contexts_kind_and_evidence.md) | Active — Next | Finish family submission, scoped completion and exact recovery/read-back; account for retained controlled-publication metadata, then validate automatic kind preparation, real cases and mutations. Earlier evidence remains historical. |
| 2 | [Vault, MinIO and bootstrap](phase_02_vault_minio_and_bootstrap.md) | Active | Reopened for backup integrity; validate the real scenario and isolated mutation after Phase 1 preparation is proven. |
| 3 | [Authority and local lifecycle](phase_03_authority_and_local_lifecycle.md) | Active | In progress; resume after the reopened Phase 2 regression is resolved and revalidated. |
| 4 | [Ephemeral credentials](phase_04_ephemeral_credentials.md) | Planned | Phase 3 complete plus real AWS test account/elevated fixture. |
| 5 | [First complete AWS lifecycle](phase_05_first_complete_aws_lifecycle.md) | Planned | Phase 4 complete; cheap real resource create/recover/delete/read-back. |
| 6 | [Local platform and applications](phase_06_local_platform_and_applications.md) | Planned | Phase 5 complete; canonical local services, registry, storage and application behavior. |
| 7 | [Public edge, email and users](phase_07_public_edge_email_and_users.md) | Planned | Phase 6 complete plus real domain/ACME/SES prerequisites. |
| 8 | [EKS and substrate parity](phase_08_eks_and_substrate_parity.md) | Planned | Phase 7 complete plus EKS budget/quotas; full AWS ownership and deletion. |
| 9 | [HA, federation and recovery](phase_09_ha_federation_and_recovery.md) | Planned | Phase 8 complete; real fault schedules and supported failure-domain evidence. |
| 10 | [Migration and final regression](phase_10_migration_and_final_regression.md) | Planned | Phase 9 complete; old-install migration, final removals and repeat already-proven journeys. |

## Adoption state

The accepted target uses retained local kind with Vault, MinIO, the existing management roles and application services. Ordinary target `delete` removes all deployment-owned AWS resources and updates retained local state; it does not remove its own management cluster. Production/test roots and credentials are isolated. [Product architecture](../documents/engineering/product_architecture.md) owns these decisions.

The documentation adoption itself did not implement the target. Subsequent
Phase 0 and Phase 1 work has changed code and tests, but the current binary
still exposes legacy commands and lifecycle behavior alongside incomplete new
work. Use its actual help for live operations until each replacement slice is
delivered. Historical test totals and the recent manual AWS cleanup are not
qualification of the target.

Phase 0 closed only after the checker migration, adverse fixtures, isolated
mutation campaign, owned removals, and post-removal canonical gate. Phase 1 is
the current implementation entrypoint. Historical snapshot availability limits
remain recorded in the Phase 0 evidence; they are not new runtime qualification.

## Implementation inputs

- [Objective dispositions](objective_dispositions.md): each retained, replaced or retired product objective and its numerical owner.
- [Command dispositions](command_dispositions.md): every current command and meaningful option mapped to its replacement/internal/removal outcome.
- [Acceptance cases](acceptance_cases.md): real public-command scenarios, observers, negative controls and cleanup.
- [Mutation cases](mutation_cases.md): named critical source defects and expected unchanged assertion failures.
- [Legacy removal ledger](legacy_tracking_for_deletion.md): every obsolete route, helper, document or artifact with a remover and proof.
- [System components](system-components.md) and [substrates](substrates.md): target catalog and local/AWS projection.
- [Evidence rules](evidence/README.md): non-secret identities, availability and report binding.

These Markdown manifests are canonical. Do not create separately maintained YAML inventories or a second execution queue.

## Closing a phase

Follow the owning phase's acceptance and critical mutation set against real completed prerequisites. Independently verify introduced resources and their cleanup. Resolve every owned removal row, align documentation/generated references, and record the actual source/build/config/evidence identities before updating state here and in that phase.

If a required external prerequisite is unavailable, record it as such and preserve work. If validation needs later unfinished code, fix the phase boundary rather than substitute a fake or defer the proof. The final phase repeats earlier public journeys; it is not permission to leave them private or unproven until the end.

## Historical material

[History navigation](../documents/history/README.md) identifies the pre-refactor source identity and preserved inputs. Historical phases and completed claims retain their original scope. They are regression material, not the active queue or automatic closure evidence for the replacement.
