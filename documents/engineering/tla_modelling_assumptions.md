# Formal Model Correspondence and Limits

**Status**: Authoritative source
**Supersedes**: Pre-refactor formal-model correspondence claims
**Generated sections**: none
**Applicability**: Evidence boundary for existing unchanged models and the accepted target.

> **Purpose**: Keep useful formal checks while preventing old models from certifying a new runtime by implication.

## Existing source artifacts

[Model index](tla/README.md) lists the current `.tla`/`.cfg` artifacts. This Markdown adoption changes none of them or their Haskell runner. Their previous results bind their original source/configuration and assumptions, not the new kind command topology.

The Orders ownership model addresses the declared finite selection/ownership rules. The legacy liveness model is explicitly pre-cutover continuity work. The lifecycle-create model and its superseded counterexample configuration address ordering of resource identity registration and external effects. Preserve the expected-counterexample control: a model observed only where it passes does not establish that its checker can reject a broken rule.

## Required correspondence record

For a retained current claim, identify model variables/actions/invariants, exact runtime owners/adapters and data/operation identities, fairness/failure/time/storage assumptions, bounds, expected TLC disposition, actual command/output/source identity, and the real runtime scenario that exercises the same failure class. Record any missing correspondence as a limit, not solved by a constructor name.

A model cannot establish actual mount persistence, AWS eventual consistency or permission behavior, physical worker settlement, process memory fit, network isolation, public TLS, or credential retirement without the separate real evidence. Unknown provider state does not become global world-state knowledge because a finite model omitted the unknown arm.

## Numerical ownership

Phase 0 inventories models/claims and migrates document references without editing or rerunning their source. Phase 1 establishes reproducible tooling where needed. Consuming phases use useful pure laws and real-component tests. Phase 9 validates retained HA/ownership/continuity correspondence and retires obsolete model claims/source through L17; Phase 10 removes migration-only residue only after its obligations end.

Do not create a larger formal framework as an alternative to completing the public acceptance cases. Targeted source mutations complement model counterexamples and real fault runs; each proves its declared scope.
