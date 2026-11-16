# Development Plan Standards

**Status**: Authoritative source
**Supersedes**: N/A
**Generated sections**: none
**Applicability**: Adopted numerical execution and phase-completion contract.

> **Purpose**: Make implementing open phases in numerical order produce the accepted prodbox architecture, with real validation and explicit removal ownership.

## Execution order and authority

[README.md → Resume Here](README.md#resume-here) is the only current queue. Work the first incomplete numerical phase. Phase N may depend on completed phases 0 through N−1 and declared external prerequisites. It must not need code from N+1 to validate or close.

There are no backward dependencies, hidden queues, or indefinitely expanding decimal sprints. Use stable tasks inside the owning phase. If a real dependency points forward, correct the boundary/order before introducing a workaround. Later phases extend earlier contracts; they do not silently reverse delete scope, ownership, root isolation, credential ingress, or evidence semantics.

The accepted engineering contracts describe the target. Current command availability comes from the actual registry/binary. Existing code and historical completion labels are reusable inputs, not proof of the replacement. Every implementation phase activates its completed public slice; the final phase is regression/migration, not the first operational cutover.

## Canonical plan structure

| Surface | Owner |
|---|---|
| Current numerical queue and next action | `README.md` |
| Static navigation | `00-overview.md` |
| Phase contract and task/evidence status | `phase_00_...md` through `phase_10_...md` |
| Product objective disposition | `objective_dispositions.md` |
| Every existing command/meaningful option disposition | `command_dispositions.md` |
| Required real acceptance cases | `acceptance_cases.md` |
| Critical source mutation definitions and assertion bindings | `mutation_cases.md` |
| Obsolete code/docs/artifact removal | `legacy_tracking_for_deletion.md` |
| Target service and responsibility catalog | `system-components.md` |
| Local/AWS projection and resource ownership | `substrates.md` |
| Evidence storage, identities and availability | `evidence/README.md` |

These Markdown manifests are canonical. Tooling may derive machine-readable views, but must not maintain competing inventories. The old hyphenated ledger and old phase filenames are temporary deprecated forwarding material only; their removal is owned in the new ledger.

## States and closure

| State | Meaning |
|---|---|
| `Planned` | Contract and owner exist; earlier phases may still be incomplete |
| `Active` | Work has started; remaining tasks and next action are explicit |
| `Blocked` | A named earlier-phase or external prerequisite currently prevents required work |
| `Complete` | All declared acceptance, mutation, cleanup, documentation and owned removal obligations passed |

Implementation task status is separate from phase completion. There is no `Complete, live proof pending` escape for a phase whose acceptance requires real infrastructure. Missing external credentials, quotas or provider availability may block that phase honestly; they do not justify fake closure or a dependency on unfinished later product code.

A reproducible regression reopens its owning phase. Identify affected downstream evidence and rerun it before restoring those completion claims. Keep prior reports immutable and attributable. Do not overwrite a failed result with a narrative success or rename the same failure repeatedly as a new class.

## Required phase contract

Every phase file contains:

- Phase number, state and owned product outcome.
- Prior-phase and external prerequisites, with no larger-numbered phase dependency.
- Stable tasks, actual implementation locations where known, and the public behavior activated.
- Introduced resource families and their creation, observation, recovery and deletion obligations.
- Real happy-path, adverse, interruption/resume and cleanup cases linked by acceptance ID.
- Independent observers, negative controls and critical mutation IDs with expected assertion failures.
- Source/build/config identity and evidence availability requirements excluding secret material.
- Owned removal rows, documentation changes, completion criteria and remaining work.

Do not give a task an implementation path that does not exist without marking it proposed. Do not list a removed test as current evidence. Optional later capabilities are outside a phase's claim, not skipped requirements counted as passed.

## Real acceptance requirements

Run the built public binary through the real interpreter and actual owned dependencies. Phase N exercises its real predecessors; it does not replace an incomplete future dependency with a fake and call the composition complete.

Pure tests and protocol fixtures remain valuable, but cannot establish provider/Kubernetes behavior, persistence, actual credential retirement, network enforcement, resource fit, public TLS, or service readiness. Rendering a manifest, constructing a proof value, or receiving exit zero is insufficient for those claims.

Each external mutation has an independently observed postcondition under the same deployment/account/region/resource scope. Record unanswered observations as incomplete. Positive controls establish that an apparently empty inventory can actually observe its field. Exact cleanup is required for every resource family introduced in that phase, including partial creation and lost replies.

Independent observers require negative controls: wrong identity, wrong account/region, missing evidence, fabricated/stale receipt, withheld effect, retained residue and blind observation must fail the relevant assertion. The outer harness retains unmodified authority over isolation and cleanup.

## Targeted source mutation gate

[mutation_cases.md](mutation_cases.md) owns a small reviewed catalog of critical semantic source changes, extended around changed lifecycle code. Use one mutation per isolated non-secret source snapshot and a passing unchanged baseline. Exercise the actual mutated implementation with unchanged tests.

`Killed` requires the designated behavioral assertion/test failure. Compilation errors are `Invalid`; unrelated crashes, unavailable dependencies and generic timeouts are `Inconclusive`. A surviving non-equivalent critical mutation blocks phase closure. Equivalence exclusions need a documented source/contract-bound review; replace meaningless candidates when possible. Silent skips and a global mutation percentage cannot satisfy the named cases.

Bind results to baseline/build, patch, test selection, intended and actual assertion, duration and cleanup. Rerun affected cases when the implementation, tests, observer or mutation changes. Enforce fixed execution budgets.

Mutants cannot receive real AWS/elevated fixture credentials, production roots, current kubeconfig, unrestricted container sockets, publication credentials, or provider egress. An unmodified outer runner may lend a reviewed disposable local interface. Real AWS/public-edge acceptance always uses the separately identified unmodified build. Mutation evidence supplements that acceptance.

Phase 0 proves checker mutations manually in scratch copies using existing tooling. Phase 1 automates bounded mutation execution and verifies its outcome classification. Later phases use that completed capability; no phase waits for a future adapter to kill its own current critical mutations.

## Resource and credential lifecycle

Every introduced resource has one recorded owner and cleanup path before effects. Record provider/IAM intent before the first possible mutation, including credential bootstrap. Use stable operation identities for resume. Never infer resource absence from a missing checkpoint, directory or current Vault initialization state.

Keep `.data/` production and `.test-data/` testing isolated by roots, cluster/context identities, endpoints, credentials and cloud ownership. Production/test SES resources are distinct. A campaign may reuse its own SES resources across cases; explicit deletion removes the owning campaign/deployment's resources.

Elevated AWS input uses the real prompt or the `test-secrets.dhall` prompt simulator and remains ephemeral at runtime. Generated operational credentials live in scoped Vault state. Credentials and recovery capability outlive their dependants; verify IAM and Vault retirement independently. Tests cannot copy production configuration or use ambient auth as a substitute.

Every durable refusal has a bounded self-heal, an exact input requirement, or an explicit supported recovery disposition. Missing evidence is not permission to reset identity or custody.

## Evidence and live campaigns

Evidence records scenario/case IDs, source-manifest and binary/image identities, non-secret config projection, environment/deployment/operation scope, commands, timestamps, observations, primary outcome and cleanup. Preserve failed evidence. Never ingest or publicly hash plaintext secrets.

A session makes at most three AWS-spending attempts without a new offline reproducer for the last observed failure. Batch known fixes per image roll. After three consecutive live runs that each stop at a new boundary, review the failure class and sibling states before spending on another run. New-boundary progress is diagnosis, not phase closure.

A defect class closes through a recorded real-behavior regression, the relevant real canary/acceptance, and the declared repeated clean cycles. Two clean cycles are an entry to reliability testing, not proof of permanent correctness. State the actual load, failure schedule, resource envelope, failure domain and repetition/soak budget supported by the evidence.

Manual infrastructure changes explicitly requested by the operator remain hand actions. Record them; they do not qualify a supported lifecycle run. Ordinary test setup, cleanup, residue injection and recovery use registered prodbox paths.

## Legacy removal ownership

[legacy_tracking_for_deletion.md](legacy_tracking_for_deletion.md) is the sole active removal ledger. Every row has an ID, concrete locations, reason, replacement, numerical remover, earlier/current prerequisites, replacement acceptance, absence check and state. No row is unowned.

The owner is the phase that removes the item. A phase cannot close while its rows remain pending. Split families with different removal conditions. A replacement cannot be called fully delivered while its ordinary predecessor remains a second writer. A narrowly fenced original-install migration lane can remain only under its explicit later removal owner.

`Removed` requires both safe replacement evidence and absence of the old active route. Deleting a scratch directory or finding no source match does not prove resource cleanup. Preserve needed regression inputs before removing temporary aliases or historical codecs.

## Documentation and adoption

Change the owning contract first, then numerical task/acceptance/removal ownership, implementation, actual validation and closure. Follow [Documentation Standards](../documents/documentation_standards.md). Keep stable architecture free of dated implementation diaries.

The current adoption request changes Markdown only. It completes the documentation subtask, not Phase 0's executable checker migration. `CheckCode.hs` still recognizes old paths, sprint grammar and generated-section rules; the first implementation session must migrate those rules and their negative/mutation tests before claiming `prodbox dev check` passes under this contract. Do not bypass or weaken the checker to obtain green output.
