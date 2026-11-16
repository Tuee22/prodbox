# Code Quality and Generated Artifacts

**Status**: Authoritative source
**Supersedes**: Pre-refactor quality-gate correspondence and generated-artifact doctrine
**Generated sections**: none
**Applicability**: Adopted target contract; Phase 0 still owns checker migration

> **Purpose**: Define one manually invoked quality gate and trustworthy generated/documentation checks.

## Canonical gate

`prodbox dev check` remains the single development entrypoint for repository policy, formatting, lint, warning-clean build, selected test routing, documentation structure and generated drift. No repo-owned `.github/` workflow or git hook is introduced. Agents never commit, push, add to the index or otherwise mutate Git state.

The current checker hardcodes old phase/ledger paths and generated doctrine sections. Documentation adoption intentionally precedes its Phase 0 implementation migration because the user restricted this session to Markdown. Do not claim the old checker validates the new contracts, disable checks globally, or mark Phase 0 Complete before the corresponding real code/tests pass.

## Required generated surfaces

One typed source generates parser/help/man/completions/command JSON/tree/reference, service/route/resource facts, role configuration schema and shared chart artifacts where they are derived. Human architecture explains decisions and proof boundaries. Do not hand-edit a generated current-binary inventory to make the target appear implemented.

Generated sections carry matched markers, declared header keys and a registry owner. Check mode compares exact expected output and changes nothing; generate mode deliberately writes it. Update registry/markers/metadata together when code changes their format. A missing scoped source or generated owner is failure, not an empty successful scan.

## Documentation and plan structure

The [documentation standards](../documentation_standards.md) own headers, canonical ownership and links. The [plan standards](../../DEVELOPMENT_PLAN/development_plan_standards.md) own phase states. The checker migration must read Markdown manifests for objectives, commands, acceptance/mutation definitions and the snake_case deletion ledger; it cannot silently continue evaluating the old sprint queue.

Check numerical dependencies, unique owners, complete old-command/option disposition, acceptance/mutation IDs, result/source bindings and pending-removal ownership. Plant invalid examples proving each check rejects its intended defect. Mechanical validation establishes structure and references, not the truth of a self-authored evidence claim.

## Test and mutation routing

Every declared Cabal/scenario suite has one runnable route and explicit claim scope. A suite compiled but never run cannot substantiate doctrine. Targeted mutation execution remains bounded and integrated with the existing test/evidence runner; schema validation alone does not establish a kill. Real-provider acceptance remains separate and uses unmodified code. [Testing](testing.md#targeted-mutation-testing)

Run checks appropriate to a change. After success, repeat/broaden only for new edits, failures or unresolved concerns. A documentation-only change needs link/header/plan/disposition checks and honest reporting of any current checker mismatch; it does not justify a live AWS campaign. An owning runtime phase must run its real closure set and cleanup.

## Source and evidence hygiene

Keep operational/generated roots, secret fixtures and credentials outside source/build contexts. Source manifests use an explicit non-secret policy and exclude secret/data/build roots. Evidence retains source/build/config projections and availability without plaintext secret hashes. Never prune historical inputs still required by a registered regression merely to reduce workspace size.

Code-local tests, compiler warnings and test counts do not establish public lifecycle correctness. Every new resource family, refusal and migration route needs real completion/recovery evidence in its introducing phase and removal ownership for its predecessor.
