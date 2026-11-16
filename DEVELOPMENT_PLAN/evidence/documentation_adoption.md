# Markdown Adoption Verification

**Status**: Reference only
**Supersedes**: N/A
**Generated sections**: none
**Applicability**: Documentation-only adoption record; not Phase 0 runtime/checker completion or infrastructure qualification.

> **Purpose**: State what was actually checked and the exact unchanged-tooling limitation handed to the next implementation session.

## Authorized change

Only Markdown was refactored. No Haskell, Cabal, Dhall, YAML, JSON fixtures, TLA source/config, generated non-Markdown artifacts, credentials, local storage or infrastructure was changed by this adoption. Git status/diff inspection verifies that every changed/new repository path ends in `.md`.

Accepted doctrine and phases are now canonical. Phase 0 remains Active for executable checker/registry adoption, actual checker-negative fixtures and M00 source-mutation proof. Later phases are Planned. This record is not a substitute for A00-01 through A00-04.

## Structural checks

A direct read-only Markdown audit checks required metadata, balanced fences, final newlines/whitespace, resolving active relative links/anchors, unique numerical phases/states, acceptance/mutation references, and exact phase-to-ledger ownership. Historical quoted source is explicitly historical, not active navigation or policy.

The adopted inventories contain 138 captured command leaves and 65 distinct captured long-option names, plus explicitly identified parser-only helpers/options and positional operands absent from the captured JSON. Phase 0 must mechanically reconcile source/parser/registry to close that discovered projection gap. All 81 former pending removals have individual B IDs and numerical removers; 21 removal families cover new/superseded paths. There are 59 real acceptance cases and 14 critical source-mutation families.

The current generated command-table payload in `documents/cli/commands.md` remains byte-for-byte equal to its pre-adoption body. Handwritten applicability/navigation around it changed; parser/help/source did not.

## Existing checker result

The actual unchanged command was run:

```text
./.build/prodbox dev lint docs
Exit: 1
Missing start marker `<!-- prodbox:resource-lifecycle-classes:start -->` in `DEVELOPMENT_PLAN/substrates.md`.
```

The adopted substrate document describes target ownership rather than retaining old generated lifetime classes as target doctrine. The old code still requires its original marker location and has further hardcoded old phase/queue/ledger/document assumptions. Phase 0 P00-T01 migrates those registry locations and validations with their real tests. Audit all such assumptions; the first reported marker is not claimed to be the only mismatch.

Do not restore contradictory doctrine or disable checks to obtain a green result. No full `dev check` success is claimed for this Markdown-only adoption. The next session may edit code only when requested to implement the open phases; it starts with this explicit tooling work.
