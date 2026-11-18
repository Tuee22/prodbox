# Critical Source Mutation Cases

**Status**: Authoritative source
**Supersedes**: N/A
**Generated sections**: none
**Applicability**: Target validation contract; no mutation result is claimed by writing this catalog.

> **Purpose**: Define the bounded source faults and intended assertion failures required to validate critical lifecycle tests in numerical phase order.

[Acceptance cases](acceptance_cases.md) define real unmodified workflows. This catalog defines deliberate implementation faults used to determine whether unchanged tests detect violations of those same invariants. A source mutation is distinct from changing a test input, injecting infrastructure failure, or changing an AWS resource. Each owning phase must establish its required result before it closes; phase state lives only in [README.md](README.md#resume-here).

## Required catalog

Each family below expands into named variant records in the owning implementation. Every variant records exact patch-site preconditions, baseline source/build/toolchain identity, patch digest, selected unchanged tests, expected assertion/test ID, execution budget, observed result and outer cleanup. A missing/changed patch site is not a silent skip. The first owning phase cannot require a later adapter; later phases extend the relevant family to the real adapters they add.

| Mutation | First owner | Required semantic variants | Intended unchanged assertion | Acceptance binding |
|---|---:|---|---|---|
| M00 | 0 | Disable future-phase dependency rejection; disable removal-owner validity; accept missing/foreign evidence references; admit a known missing current source | `plan.rejects_future_dependency`, `plan.requires_valid_remover`, `plan.requires_bound_evidence` and `plan.rejects_missing_source` each fail for its own malformed-plan fixture | A00-02, A00-04 |
| M01 | 1 | Remove environment/root/context or Docker effect ownership checks; admit a cross-root alias, foreign context, foreign network removal or unowned pull | The corresponding unchanged `context.rejects_foreign_scope`, `context.rejects_root_alias`, `context.rejects_foreign_network` or `context.rejects_unowned_pull` assertion fails without touching real production | A01-03, A01-07 |
| M02 | 1 | Evidence validator accepts absent, fabricated, stale or wrong-scope results | `evidence.rejects_unbound_result` fails on the corresponding adversarial report; observer meta-test stays unmodified | A01-06, A01-07 |
| M03 | 2 | Permit test MinIO self-unseal in production policy; call init over a recorded storage-generation mismatch | `bootstrap.production_rejects_test_unlock` / `bootstrap.preserves_vault_incarnation` fail | A02-03, A02-04, A02-05 |
| M04 | 3 | Recode an unobservable resource/journal or missing existing history as absence / NeverAdmitted | `lifecycle.unknown_requires_recovery` / `lifecycle.missing_history_is_not_fresh` fail | A03-02, A03-03, A03-04 |
| M05 | 3 | Return `NoChange` while a durable admitted operation remains unresolved | `lifecycle.pending_intent_blocks_noop` fails | A03-01, A03-04 |
| M06 | 4 | Omit IAM intent registration before the first possible create; revoke an operational credential before its resource dependants are terminal | `credentials.intent_precedes_effect` / `credentials.dependants_precede_retirement` fail | A04-01, A04-02, A04-03 |
| M07 | 5 | Skip a required provider delete, skip its independent read-back, or retire checkpoint/recovery custody before absence | `delete.requires_resource_absence` / `delete.requires_readback` / `delete.preserves_recovery_custody` fail | A05-01, A05-02, A05-03, A05-04 |
| M08 | 5 | Make an independent observer return `Clean` despite retained residue, denied inventory or unanswered query | `observer.rejects_residue` / `observer.unanswered_is_unobservable` fail under independent unmodified meta-tests | A05-03, A05-04 |
| M09 | 6 | Bypass application persistence, desired-selection or dependency checks | `services.preserves_data_binding` / `services.deleted_selection_stays_absent` / `services.requires_dependencies` fail | A06-03, A06-04 |
| M10 | 7 | Omit an owned DNS/SES/S3/IAM family; retain the former SES exemption; mutate another environment's receipt rules or replace/deactivate its active regional rule set | `delete.covers_owned_families` / `email.retains_foreign_receipt_rules` / `email.test_cannot_switch_production_receiving` fail | A07-02, A07-04, A07-05 |
| M11 | 8 | Omit an EKS controller-dependent family; select a drain target from another stack/checkpoint | `eks.covers_controller_dependants` / `eks.drain_requires_exact_cluster` fail | A08-03, A08-04 |
| M12 | 9 | Admit a successor before actual predecessor settlement; accept stale worker or federation identity | `recovery.settlement_precedes_successor` / `federation.rejects_stale_identity` fail | A09-02, A09-03 |
| M13 | 10 | Permit old/new competing writers during import; replace the original deployment identity with a new one to escape unresolved history | `migration.exclusive_writer` / `migration.preserves_original_identity` fail | A10-01, A10-02 |

The assertion identifiers name required behavioral checks to implement; they are not claims that tests with those names already exist. A phase binds them to actual test/source identifiers before running its catalog. Pure fixtures and recorded provider contracts can isolate faults, but tests execute the actual mutated implementation rather than a hand-written description of its expected behavior.

### Phase 1 preliminary assertion binding

The missing-report variant of `evidence.rejects_unbound_result` is bound to
`scenario evidence comparison.rejects an unbound report for the mutation catalog`
in `test/unit/ScenarioEvidenceTests.hs`. Its marked assertion exercises
`compareScenarioEvidence` in `src/Prodbox/Test/ScenarioEvidence.hs`. This binds
one adverse case only. `Prodbox.Test.ReviewedMutation` defines the first
source-bound candidate: for source SHA-256
`e838f617e90537a56bc7ee9af2e113bb9a5bc939dfe95c4c663dece5645b22f1`, it
replaces the single adjacent report/observer lookup with a lookup that
constructs a report from the supplied observer when the report is absent. The
candidate must match that exact preimage and one site; a changed source needs a
new review. Its domain-separated implementation-binding digest is
`6a953a78bf1ac83ffa3878581d4f65005adc43281a3a371e417ed4cb7ba9d944`;
the resulting source bytes hash to
`121bd7e3312b33fab6f8177b356643d9c45b6eadfcb973fc26d20438d0da37e4`.
These are not unified-diff hashes. Preparing candidate bytes is not a mutation execution. The
isolated execution, observer meta-test, remaining M02 variants and mutation
result are still open.

The reviewed M01 overlapping-root variant is bound to
`deployment scope coordinates.rejects overlapping roots for the mutation catalog`
and `context.rejects_root_alias`. It changes the root-overlap check in
`src/Prodbox/Config/DeploymentScope.hs` so it cannot reject valid API ports.
The required source SHA-256 is
`e38d6ca4908cfe91172784dc124fc46777e9ef94a3ff456b88543f28e808515a`;
the domain-separated binding digest is
`c289b3516dd857de5a183e22f5029af04bd315a70f6d965e0ddc7590a0a30a94`
and the candidate source SHA-256 is
`50cebd8ad38611570c2e90e2554b2a640df9b449e4d36bb5bf43d0060de6bbb6`.
The baseline assertion and preparation passed; isolated compilation, actual
assertion failure, cleanup and M01 acceptance remain open.

### Phase 0 assertion bindings

These bindings identify unchanged assertions in `test/unit/Main.hs`; they are
not mutation results. The first three are in `numerical phase plan contracts`,
and the final assertion is in `Sprint 0.21 citedSourcePathsInDoc`. Both groups
exercise `src/Prodbox/CheckCode.hs`.

| Assertion ID | Selected test | Required failure |
|---|---|---|
| `plan.rejects_future_dependency` | `rejects future numerical phase dependencies including range endpoints` | The unchanged future-phase assertion fails when dependency direction rejection is removed. |
| `plan.requires_valid_remover` | `checks canonical removal row owners and duplicate identities` | The unchanged invalid-owner assertion fails when owner validation is removed. |
| `plan.requires_bound_evidence` | `requires available scoped evidence and removed owned rows before closure` | Separate missing-record and foreign-phase mutations fail their corresponding unchanged assertions. |
| `plan.rejects_missing_source` | `refuses missing or escaping source paths` | The unchanged missing-source assertion fails when a known absent current path is admitted. |

The initial M00 source variants are one change each in `CheckCode.hs`: make the
`dependency >= owner` guard false; make the removal-row owner-validity disjunct
false; make the missing-evidence guard false; make the foreign-phase guard
false; or add an early success for the deliberately absent Host/Tool fixture
path in `currentSourceObjectExists`. The last patch uses this exact guard:

```haskell
| path == "src/Prodbox/Host/Tool.hs" = pure True
```

Each patch must match its exact reviewed site
once. The unchanged test selection is the corresponding group above, and a kill requires the designated
assertion's failure, not merely a nonzero exit. The five variants were compiled
and each failed its intended unchanged assertion; baseline, identities, budgets,
and cleanup observations are recorded in the [Phase 0 evidence](evidence/phase_00_validation.md).

At checker source SHA-256
`2eef04e221c26d84c8794c4cf986c8b3c06b59d6d6981c357d8275c39b8d6464`,
the five proposed one-site patches were generated in memory as Python
`difflib.unified_diff` over the complete source with `a/` and `b/` path labels.
Their SHA-256 values are listed below to identify the candidates; regenerate and
re-review them if the source, patch generation or assertions change.

| Variant | Proposed patch SHA-256 |
|---|---|
| Future dependency | `6b8b4b8b01b3c240db252e1203eb3c7a7052b810dbd96350962ae551746e8a40` |
| Invalid remover | `ca951983a39edd484e4b520566f257a851278f8fdae3f9edfd500182c4089abe` |
| Missing evidence | `7e0f9923877daf9af1ab68b987852dd5ff54fd00c29dc3a418f14327b2f84d42` |
| Foreign evidence | `9e792e8e979f4f8851fc49411a40df57a9777585545ff2bab86e162f8ef13abf` |
| Missing current source | `aeba094c1f58ba0e97fbc97a714cf9be679784c331d426b43ac99be8608c4505` |

## Result rules

| Outcome | Meaning | Counts toward required critical detection? |
|---|---|---|
| Killed | The mutated code compiles and the designated unchanged behavioral test/assertion fails for the intended invariant | Yes, with exact failure evidence |
| Survived | Mutated code compiles and relevant tests complete without detecting the defect | No; strengthen the tests or establish reviewed equivalence |
| Invalid | Patch-site preconditions fail, the patch does not apply, or compilation/typechecking fails | No; replace with a compile-valid meaningful fault |
| Inconclusive | Baseline failure, unavailable dependency, harness crash, unrelated test failure, generic timeout, or missing result | No; repair execution and rerun within an explicitly declared budget |
| Equivalent | A documented review establishes the mutation cannot change supported behavior under the recorded contract/source identity | Only as an explicit justified exclusion; seek a meaningful replacement fault |

An unrelated test failure cannot be relabeled Killed. A timeout alone does not prove the intended fault was detected. The expected assertion remains unchanged between baseline and mutant. Do not weaken tests, delete a case or silently alter the scope to obtain a green gate. Surviving non-equivalent critical variants, invalid/inconclusive substitutes and missing required results keep the phase open.

## Execution and isolation

1. Pass the unmodified baseline using the same selected tests, trusted dependencies and toolchain. Bind results to the baseline source/build identity so a stale artifact cannot kill a new mutant.
2. Apply exactly one reviewed semantic source mutation to an isolated non-secret snapshot with a separate build directory. Do not modify the working checkout, operator executable or tests under evaluation. When testing an observer, keep its external meta-test independent and unchanged.
3. Run within fixed build, test, memory/disk and cleanup budgets declared before execution. A budget extension is an explicit new attempt, not invisible deadline refresh. Record patch identity, intended and actual assertion/test outcome, elapsed time and cleanup.
4. Dangerous ownership/deletion/credential mutants execute offline against pure or provider-boundary fixtures. They receive no real AWS credential, `test-secrets.dhall`, elevated input, operator data root, current kubeconfig, unrestricted runtime socket or artifact publication capability. Enforce isolation through the process/container boundary; environment clearing alone is insufficient.
5. Build with prepared trusted dependencies and no provider egress. An unmodified outer runner may create a reviewed disposable local fixture and expose only its exact scoped interface. It verifies cleanup independently; a mutant cannot authorize its own boundary or certify its own resource absence.
6. Never deploy/publish mutated images or binaries to production or real AWS. Live provider/public-edge qualification runs separately identified unmodified code. Mutation evidence demonstrates test sensitivity, not actual AWS/Kubernetes success.

Re-run affected variants when implementation, relevant tests, observers, patch definitions or supported contracts change. Reuse the same named invariant across the offline mutant and real acceptance scenario. Maintain small selected cases around changed critical code rather than a global mutation percentage or a mutation of every expression.

## Delivery order and cost

Phase 0 defines the catalog, result schema and closure rule and runs M00 with current build/test tooling in safe scratch copies. It does not wait for a general mutation runner. Phase 1 implements the minimal bounded executor in the existing scenario/evidence path, proves isolation and outcome classification, and reruns M00 plus M01/M02 through it. Include a real compiled surviving calibration fault and separate invalid/inconclusive executions so “any nonzero exit means killed” cannot pass.

Expose named cases through the same scenario registry, including `test run mutations`; cumulative phase execution includes the relevant owned variants. Exact-source and expected-test selectors are data in this Markdown catalog and its implementation bindings, not a second test orchestrator. Pure build/fixture cases may enter `dev check` within its declared budget. Do not run a real cloud campaign per mutant or make a generic mutation framework a prerequisite for product delivery.

Each later phase adds its current-capability variants and includes them in its own closure. Phase 10 reruns the final affected catalog; it is not the first point at which earlier mutations must detect their faults. State mutation outcome counts and scope without treating their percentage as a reliability guarantee.
