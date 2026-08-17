# prodbox Development Plan

**Status**: Authoritative source
**Supersedes**: N/A
**Generated sections**: none

> **Purpose**: Provide the single execution-ordered development plan for the Haskell rewrite of
> `prodbox`, including phase status, validation gates, and cleanup ownership.

## Standards

See [development_plan_standards.md](development_plan_standards.md) for the maintenance rules that
govern this plan suite.

## Resume Here

This is the only current-status and resumption ledger in `DEVELOPMENT_PLAN/`. A new session must
start here, then open that sprint in its phase file for the first row whose state is `Next`. Work the
queue from top to bottom. `Parked` means useful foundations may already exist but no further work
is admitted ahead of the queue; `Blocked` means the row has an unmet dependency named earlier in
the same queue.

| Order | Sprint | Phase | State | Dependency |
|-------|--------|-------|-------|------------|
| 1 | `3.41` | 3 | Next | — |
| 2 | `4.84` | 4 | Parked | — |
| 3 | `4.85` | 4 | Parked | `4.84` |
| 4 | `4.86` | 4 | Parked | `3.41`, `4.85` |
| 5 | `5.36` | 5 | Parked | `4.85` |
| 6 | `6.5` | 6 | Blocked | `4.86`, `5.36` |
| 7 | `7.36` | 7 | Parked | `4.85` |

Sprint `5.35` is Done on its code-owned frozen-oracle surface and is not an open queue row. Its
oracle remains a required gate for `5.36` and for the repository-level release checks. The
partially implemented Phase 4, 5, and 7 foundations stay preserved while parked; their presence
does not authorize skipping the numerical queue.

The mandatory control plane is the retained local RKE2 deployment containing the Lifecycle
Authority and its bounded workers/adapters. AWS is an optional target substrate, never an alternate
authority. Every supported AWS mutation begins as an authenticated `prodbox` CLI submission to
that local Authority and executes only through the permitted Provider Worker or other exact
role-specific interpreter. If the retained control plane cannot authenticate, durably register,
or observe the operation, the command fails closed; there is no host-direct `pulumi`, `aws`,
`eksctl`, or `terraform` mutation fallback.

The existing cascade remains the public writer until Sprint `6.5` performs the qualified
single-writer cutover. The replacement cannot construct completion until the pre-uninstall proof
is durable and the retained-root host record has made its exact locked `Prepared -> Absent`
transition with independent read-back. Deployment qualification remains pending and cannot be
substituted for by partially landed code or an old live run.

**Repository reconciliation checkpoint (2026-08-16).** The reconciled current tree passes the
code-owned release surface: the canonical `dev check` completed with **615 library modules** and
**194 unit modules** warning-clean; the unit wrapper passed **3,954 main + 27 admission + 33
authentication + 29 authenticated-transport tests**; the installed frozen teardown-recovery
integration passed with artifact digest
`7338a7228fb7c79929d23f64af285d5daa0b180918c7bea694897972a255b76d`; and generated docs,
documentation lint, chart lint, Fourmolu, HLint, and diff checks are clean. These results validate
the repository checkpoint but do not close or reorder any row in Resume Here.

The combined CLI/environment integration binary was also exercised from the reconciliation host.
Its stale fake-Kubernetes ServiceAccount namespace was corrected to preserve the exact operator
(`bootstrap-broker`) and harness (`gateway`) identities; every affected config/Authority case then
passed. The resulting macOS run was **44/60 passed and 16/60 refused or failed**, with every
remaining failure entering a Linux-only RKE2/gateway surface. That is an explicit pending
supported-Linux qualification boundary, not a code-owned regression and not evidence against the
mandatory retained-local-control-plane architecture. Rerun `prodbox test integration cli`,
`prodbox test integration env`, and the applicable Standard-P live qualification inside the
supported Linux RKE2 frame before claiming deployment closure.

## Historical Closure Record

The dated records below preserve earlier checkpoints and counterexamples. They are not a resume
ledger and cannot override [Resume Here](#resume-here).

**Paused head-state record (2026-08-16, superseded as a resume instruction).** Phases `3`,
`4`, `5`, and `7` are 🔄 Active. Sprints `3.41`, `4.84`, `4.85`, `4.86`, `5.35`, `5.36`, and
`7.36` all have real implementation in the worktree; their final closure dependencies remain
forward-only even where dependency-safe foundations were implemented in parallel. Phase `6`
remains ⏸️ Blocked on Sprint `6.5` by the unfinished candidate and `TestRunner` cutover. Phases `0`,
`1`, `2`, and `8` remain closed. No public cascade writer or legacy-path deletion has been
activated.

The paused checkpoint distinguished validated foundations from incomplete protocols:

| Sprint | Recorded implementation checkpoint | Validation / remaining boundary |
|--------|-----------------------------------|---------------------------------|
| `3.41` | The exact recovery component projection, bootstrap-owned operator identity, opaque local-RKE2 and retained-root observations, RecoveryPlane component observer, exact-name RBAC, and Authority API egress are landed. | Code-local library/unit/chart gates passed. A recovery-only renderer and immutable absent-cluster RKE2/OCI artifact inventory do not exist; stopped/absent live proof remains pending. |
| `4.84` | Pure lifecycle model/registry/observation/decision foundations, ARN normalization, exact Authority read-back seams, and public-proof opacity closures are landed. | The old unkeyed public composition and incomplete legacy-escape inventory remain. Stable registered-stack lifecycle generation and a complete terminal-audit catalog are not yet available. |
| `4.85` | Lifecycle-owned `CleanupRun`/runner, result-indexed Program/Graph/Execution/Report, canonical program descriptors, descriptor-bound restart, RecoveryCapability/Requirement, ownership/checkpoint/read-back repositories, and opaque cleanup clients are landed. | Total-decommission parity, stable create-generation binding, terminal-audit reservation/read-back, and several final proof joins remain. |
| `4.86` | RecoveryPlane identity/repository/interpreter, authenticated routes `56`/`57`, production component observation, host runtime, and a source-stable total descriptor-bound dispatcher foundation are present. | The dispatcher still needed the paused current-tree aggregate. Cascade pre-uninstall authority and the required locked `Prepared -> Absent` host-absence/completion protocol remained incomplete. |
| `5.35` | The standalone `TEARDOWN-2026-08-15` oracle, canonical artifacts, 25-row external-state matrix, 80 interruption rows, mutation fixture, and installed command are code-locally green. | The current paused tree has not rerun the full canonical quality gate; replacement production integration and live qualification are outside this sprint. |
| `5.36` | `LifecycleCleanupClient` now speaks only the authenticated descriptor-bound protocol and was focused-test green. | `TestRunner` and `DurableCleanupComposition` still own the old callback graph/executor, mutate before descriptor registration, and have not cut over. |
| `7.36` | Exact stack/checkpoint/drain/read-back repositories and routes, Provider AWS-scope receipt, creation/ownership observation routes, and registered-target interpreters are landed on bounded foundations. | Stable cross-run stack generation, a credential-session-bound causal create admission, complete escape-audit reservation/catalog/receipt, and live all-three-stack proof remained. |

The last combined compile/link checkpoint before the paused follow-on work was **610 library modules +
193 unit modules under `-Werror`**, with an immediate same-builddir no-op. The last complete unit
runtime checkpoint was **3921/3921** on the preceding 604-library/192-unit source set. Those are
historical green baselines, not validation of a later worktree. The source-stable descriptor
dispatcher had passed Fourmolu and HLint but still awaited the next serialized aggregate.

The trigger is a taken counterexample, not an infrastructure accusation. AWS's Tagging API answered
successfully with one `ResourceTagMapping` for an intentionally retained bucket and its full
two-tag set; Prodbox's decoder emitted two internal rows, copied that global answer to all three
per-run stacks, and selected EKS drain even though every exact stack observation remained
`Unobservable`. Postflight partitioned both internal rows as retained and its renderer displayed the
ARN once. The preliminary
caller-ServiceAccount observation reported “not observable”, but discarded stderr means the trace
does not establish whether the Kubernetes API was reached or why that observation failed. No drain
request reached the Kubernetes API and no Pulumi destroy reached a provider effect. The evidence
supports a Prodbox identity/scope/cardinality and observability-composition failure; it does not
support blaming AWS or Kubernetes.

The replacement is comprehensive: a pure lifecycle-indexed registry whose EBS families have
separate statically classified test-scoped `PerRun` and production-retained `LongLived` identities
rather than one identity whose cleanup policy is partitioned through runtime tags; distinct exact resource,
checkpoint, and audit observations; ARN normalization; total desired-absence decisions; closed
result-indexed programs; a lifecycle-owned durable cleanup kernel; bootstrap-owned minimal recovery;
exact AWS adapters plus write-ahead and bounded admin-confirmed legacy-adoption manifests;
proof-carrying completion; and local RKE2
uninstall only from exact convergence plus terminal-audit evidence, a backed-up pre-uninstall
report, and a one-shot permit,
followed by exact host-absence and read-back local-completion evidence. The live run falsifies Sprint `4.82`'s pending
acceptance criterion, so Standard O cannot preserve that composition claim. Both substrate
qualification rows remain `pending` under Standard P.

### Earlier closure record

**Prior head state (2026-08-15 — Sprint `3.40` ✅ closed by changed-arm live proof.)**
Every phase is ✅ closed on its code-owned surface. `3.39` separates the
pre-Vault Bootstrap Broker apply from readiness that only the following Vault step can produce and
prevents a readiness timeout from selecting destructive Helm cleanup. `4.83` separates the declared
`repository:tag` pull reference, host-local rollout token, and Kubernetes-observed runtime
attestation identity. Ledger, derived by counting rows rather than carried forward: **pending 68 →
64, unowned 2 → 2, completed 303 → 307**. Evidence: warning-clean all-target build and `dev check`
exit 0; `test unit` exit 0 at main Hspec **3482** plus 27, 33, and 27; `test integration cli`
**57/57**; and `test integration env` **57/57**. Outstanding live proofs remain Standard-O/P
qualification evidence and do not reopen code-owned phases. The aggregate then proved that the
component graph immediately recreated `3.39`'s circular wait with `ProbeRolloutComplete`; `3.40`
replaces that pre-Vault gate with an observed-revision admission. The live reconcile crossed that
gate and entered Vault initialization before the already documented retained-journal refusal. The
ledger is therefore **pending 64, unowned 2, completed 308**; aggregate qualification remains
pending under Standard P.

**The registration named the right remedy and the wrong layer to carry it, and one command settled
which.** Sprint `2.51` was registered saying `ControllerImageObservation` must carry both image
identities and that this "reaches `SecretWorkerIntent`" — the **durable** type, whose codec is
generic `Serialise`: positional and arity-checked. Measured rather than reasoned about, a record
widened by one field fails to decode its predecessor's bytes with `DeserialiseFailure 1 "Wrong number
of fields: expected=5 got=4"`. **That failure is recoverable by nothing this plan has built**:
`decodeStoredEnvelope` returns `BootstrapStoreCorrupt` at the envelope, and `recoverStoredWorker` —
including Sprint `2.50`'s roll of a superseded pre-receipt checkpoint — runs only after a successful
decode. The registered shape would have wedged the operator host permanently, on exactly the surface
Sprints `2.47` and `2.50` each closed a permanent wedge.

**The correct layer is the one the sprint's own doctrine argument already implied**, and moving there
gained a check rather than only surrendering one. A pull reference is *where the kubelet looks*; the
runtime digest is *what is proven*. It is now observed afresh at Pod creation — the one point both
the fresh and the resumed path pass through — the durable intent is unchanged byte for byte, and the
boundary now refuses when the freshly observed controller digest no longer matches the intent, which
nothing checked before. A second, never-registered instance in the same module (the Vault
pristine-reset Pod) was fixed with it.

**The proof passed on the arm it changed, and the bring-up stops strictly further along.** On a
wiped-and-rebuilt cluster the secret-worker Pod is declared as `…/prodbox-runtime:prodbox-<machine-id>`
rather than `@sha256:<config digest>`, it **pulled and ran** instead of sitting in
`ImagePullBackOff`, and its observed `imageID` `sha256:82ae5092…` is **identical to the
controller's**. The run then fails at a different cause — the worker exits `1` logging `Root
initialization journal is not pristine` — which this sprint does not own.

**That same proof caught the sprint under-implementing its own headline deliverable, and the way it
escaped is the transferable part.** The decode-collapse work landed at two call sites and **not** at
`workerRequestFromRunningResponse` / `workerRequestFromSelfResponse` — the two functions the
registration named explicitly. Because that arm compiles either way, `dev check`, 3479 unit cases,
and both 57/57 integration suites passed over it; what exposed it was the bring-up printing `worker
Pod response is invalid` four times with no reason attached, **the exact string the sprint existed to
delete**. A deliverable phrased as removing a collapse is verified only by observing that the
collapsed value is gone, and no local gate here could make that observation.

**A sweep for the same defect elsewhere found three candidates and measured all three away, which is
worth more than a fourth fix.** Three Pod images outside the Broker build `repository@<digest>` with
`imagePullPolicy: Always` from `docker image inspect --format {{.Id}}`. That reads as the same defect
and is not one: measured on the operator host, `.Id`, `.RepoDigests`, and the registry's
`Docker-Content-Digest` all agree, while Kubernetes' `imageID` is a different value. **`docker
inspect` and the kubelet are different reporters**, and carrying this sprint's measurement across to
the other one was the error — caught only because the value was read rather than reasoned about. What
survived as Sprint `4.83`, now closed: those references had been pullable only because this host runs
Docker's containerd image store, under which `.Id` *is* the manifest digest. They now use the declared
tag regardless of daemon configuration; the observers parse Kubernetes `imageID` and compare its
runtime config digest with the signed intent rather than comparing the authored spec with itself.

**And taking the proof exposed the entry's most consequential finding, which is not about images at
all.** The first attempt ran the **old binary**: `cluster reconcile` built and pushed a new runtime
image and left the Bootstrap Broker Deployment at `metadata.generation: 1` from the previous day,
with a 10h-old Pod whose `imageID` was the old image and a rollout annotation holding a digest the
Docker daemon no longer has. Generation `1` means the object was never modified — **a rollout never
requested, not one that failed**. Taken and closed the same day as Sprint `3.38` ✅: `deployChartPlan`
filtered releases on `helm list` status, so an all-`deployed` chart root produced an empty deploy set
and **a success report with no helm invocation behind it**. `helm list` carries presence and health and
no revision, so the predicate answered a different question from the one it was consumed for — the
same § 24 shape as `2.51`'s own defect, one layer up. The filter is deleted rather than made
conditional, because `helm upgrade --install` is itself the idempotent convergence operation.
Live-proven: generation `1`→`2`, the annotation moved to the image that run built, a new ReplicaSet
replaced the old, and `sh.helm.release.v1.bootstrap-broker.v2` appeared beside `v1`. **Until this
closed, every in-cluster live proof in this plan was a proof about whichever binary happened to be
deployed** — which is why the `2.51` proof above had to be taken after a full wipe and rebuild.

**And closing `3.38` made the bring-up worse before it makes it better, which is recorded here rather
than left for the next operator to discover.** With the presence filter gone, every reconcile now runs
`helm upgrade --install --wait=true` on the broker. The proving run did exactly that, then **timed
out** because the broker's `/readyz` answers `503` and never stopped, and the pre-existing
failed-release cleanup uninstalled it — **the run ended with the Deployment, the Service, and the helm
release gone**, where the stale broker would previously have been skipped and left in place. No new
code defect was introduced: `--wait=true` and the cleanup are both pre-existing and previously ran only
on first install. What changed is how often that path is reached. Sprint `3.39` ✅ closes it: the
pre-Vault Broker release applies without waiting for readiness that only the following Vault lifecycle
step can produce; other releases retain the bounded wait. A readiness timeout is now a typed
non-terminal outcome that preserves the installed release and cannot select uninstall cleanup.

**Previously (2026-08-14 — Sprints `2.48` ✅ and `2.50` ✅ close, and Sprint `2.51`
🔄 opens because closing them let the bring-up reach a defect nothing had yet seen.)** Every phase
stays ✅ on its code-owned surface; an Active sprint working a `Pending Removal` row is the shape
Standard I describes, not a reopen (Standard N). Ledger, derived rather than restated: **pending
66 → 65, unowned 2 → 2, completed 299 → 301** — two rows close and one opens. **A Standard-C correction rides with those figures, and it is the same defect this entry
is about**: the prior entry here recorded `completed 295 → 296` while the ledger's own prior entry
recorded `297 → 298`, and counting the table gives **299**. Three documents carried three different
totals for one table. These figures are derived by counting rows, not carried forward. Evidence: `dev check` exit 0, `test unit` exit 0 at main Hspec **3468** plus 27, 33, and
27, `test integration cli` **57/57**, and `test integration env` **57/57**. No phase is reopened by
this entry, no sprint is un-Done, and no deployment-qualification row moves.

**The entry's finding is that reading an object beat reasoning about it, and what it refuted was this
plan's own text.** Sprint `2.50` was registered saying the stuck secret-worker checkpoint was
"Vault-enveloped and its completion state has not been decoded" — and stated that as the reason the
failing arm could not yet be named. Both halves were wrong. The bootstrap store's `StoredEnvelope` is
canonical CBOR over `SecretFreeWorkerRequest` — *secret-free by construction*, which the type name
says outright — inlined in the MinIO object and readable with **no Vault session at all**, on a host
whose Vault is uninitialized. The sprint's caution had made the decode look impossible on exactly the
host where it was trivial. One `xxd` settled it.

**The decode then corrected a count, which is the third instance of that defect in two days.** This
plan recorded that two of the seven compared binding fields cannot repeat across invocations. It is
**three**: the operation deadline is `acceptedAt + budget`, so it is minted per invocation as
inevitably as the fence generation and the owner nonce. Same shape as the "eleven layers" numeral
withdrawn on 2026-08-14 and the "nine payload types" correction before it — **an inventory stated in
prose is not a measurement, and the difference is a command away.**

**The reason nobody caught it is the sprint's other deliverable, which makes this the first instance
whose cost is demonstrable rather than argued.** `EngineSecretWorkerStoredRequestBindingMismatch` was
payload-free and produced at **five** distinct sites, so no run could ever have reported which fields
disagreed. That is the fifth instance of the collapse Sprints `2.46`–`2.49` each closed one layer up.
Four of those were argued from the diagnoses they went on to produce; this one is argued from a wrong
number sitting in this document.

**The remedy is narrower than any of the three options registered, and the bound that scoped the
sprint is what chose it rather than being argued across.** A fence is an exclusion record and a
checkpoint is a *result* record — but that is a statement about checkpoints which **carry** a result,
and the stuck one is `InternalNoWorkerReceipt`, the constructor whose entire meaning is that no
receipt was captured. So the roll arm widened, bounded three ways: pre-receipt only; a **strictly
older** fence generation only, so the identical-binding rule is untouched within a session and a
*newer* checkpoint refuses outright; and the predecessor's worker **destroyed** by a
UID-preconditioned delete rather than observed absent — strictly stronger than Sprint `2.47`'s
absence observation, because it causes absence instead of inferring it. Exactly one of the seven cases
in the pre-existing exhaustive mismatch table changes behaviour.

**Sprint `2.48` closed the ledger row it owned rather than letting it outlive its owner.** A `Pending
Removal` row whose owning sprint has gone ✅ is the orphan shape this plan has now caught three times,
so the acquisition-path fence leak was fixed with the sprint that owned it. **Retirement could not
have served, and recording that matters because it was the obvious reach**: it requires the durable
operation deadline to have *elapsed*, and a freshly acquired fence's has not. The compensating release
needs no observation of an owner at all — it releases a fence the same call created moments earlier,
on a path where no Lease witness was obtained, and no witness means no effect can have been
authorized.

**And the 300-second coupling was declared rather than removed, on an argument that inverts the
obvious one.** Renewing the Lease looks like the cleaner fix, since then there is no relationship to
declare. It is adversarial to Sprint `2.47`: retirement takes over an abandoned fence only against a
**positively expired** Lease, and the state it exists to recover from is a bring-up abandoned partway,
so a renewer outliving the wedge would restore the permanent wedge `2.47` closed. **The Lease expiring
on its own is the mechanism, not the omission.**

**The plan briefly had no open sprint, and Sprint `2.50`'s own live proof took that away within the
hour.** The proof passed on the arm it changed — the durable checkpoint was rewritten from store
version 2 at fence generation 7 to version 4 at generation 13, which is `driveSecretWorker` rolling a
superseded pre-receipt checkpoint and nothing else in the tree writes that object. The run then failed
at a **fifth** defect in the same chain: the Broker pins its worker Pod's image to the controller
Pod's `imageID`, which on a locally-built host is the image's **config** digest, while a registry can
only resolve a **manifest** digest — so the Pod sits in `ImagePullBackOff` and every bring-up fails at
attestation. Registered as Sprint `2.51` 🔄 with **both its reproduction and its cause taken**, which
is unusual at registration and is the direct dividend of Sprints `2.46`–`2.50`: four of the five
refusals between the operator and this defect now name themselves, so each step of the diagnosis cost
a command rather than a build. **Recording it was not optional** — Sprint `2.47` was cited by this
plan before it existed as a sprint, and *registering an observation as prose is not registering it as
work.*

**The structural part of that finding is worth more than the instance.** A config digest and a
manifest digest are both `sha256:` followed by sixty-four lower-hex characters. They are
indistinguishable by syntax and distinguishable only by which endpoint resolves them, so no smart
constructor over the text can separate them — which is
[chaos_hardening_doctrine.md § 24](../documents/engineering/chaos_hardening_doctrine.md) exactly: an
observation has a layer, and this one names the container runtime's layer while being consumed as the
registry's. **And one probe taken while measuring it was wrong**: the first by-tag registry request
used only the Docker v2 manifest `Accept` header and returned 404, which reads as a lost push and
would have produced a diagnosis about the wrong half of the pipeline; adding the OCI media types
returned 200. *A measurement is only as good as the request that made it.*

**Previously (2026-08-14, later — every code-owned phase surface is closed, and the plan's
oldest open defect is closed with them).** Sprint `2.47` ✅ closes: the Bootstrap Broker now retires a
positively-expired fence and re-acquires, so a bring-up abandoned partway no longer wedges the host
permanently. Sprint `2.48` 🔄 owns the second, distinct Lease blocker recorded behind it, and its
reproduction is already taken — an Active sprint on a closed phase is the `Pending Removal` shape
Standard I describes, not a reopen
(Standard N), so Phase `2` stays ✅ and no phase is reopened by this entry. Ledger, derived rather
than restated: **pending 65 → 66, unowned 2 → 2, completed 295 → 296**. Evidence: `dev check` exit 0,
`test unit` exit 0 at main Hspec **3453** plus 27, 33, and 27, `test integration cli` **57/57**, and
`test integration env` **57/57**.

**Sprint `2.47`'s live proof passed, on the host the ledger row describes.** No reconstruction was
needed — the operator host was already in the precondition state, carrying the exact objects and
timestamps recorded on 2026-08-13: `bootstrap-session-fence` at `23:06:12`, `vault-storage-generation`
beside it at `19:09:43`, and no RKE2 install. The Broker recorded `retired expired fence generation 1;
worker-absence receipt 08f276ff…`, and the durable object was rewritten at `15:15:21`, so the CAS
reached the store rather than the decision merely being taken. **It is the Standard-P aggregate shape,
not a point probe**: across five consecutive bring-ups it retired generations **1, 2, and 3** with
three distinct receipt digests, while runs 2 and 3 refused `BootstrapFenceAcquireOverlap` on their own
merits — the negative control arrived without being contrived.

**Running it produced three findings that reading could not.** First, the ledger's paraphrase of the
second blocker is wrong: the constructor is `BootstrapLeaseObservationUnobservable`, **not**
`BootstrapLeaseNotFound`, and RBAC is ruled out by direct `can-i` measurement. Second, the
transient-RBAC-window hypothesis — the most attractive reading, matching the decoder's own comment and
an eight-second window — **died on the fifth run**; a hypothesis that explains the first observation
and not the fifth is not a diagnosis. Third, a defect nobody had recorded: `acquireFence` CASes the
fence and then abandons it when `ensureLease` fails, leaking a generation until its deadline elapses.
**Before Sprint `2.47` that leak was permanent**, which makes the retirement path load-bearing for a
defect it was not written for — the strongest available argument that it belonged on this surface.

**Sprint `2.48` then found and fixed the cause, and the fence Lease is created for the first time.**
Kubernetes parses `Lease.spec.renewTime` as a `MicroTime` with exactly six mandatory fractional
digits; Aeson renders `UTCTime` with a variable count, so the API server rejected the body `400`
**deterministically** — the Lease had never been creatable on any run, which is why `vault init` had
never got past it. Proven server-side with four falsifiable `--dry-run=server` probes, fixed by
`kubernetesMicroTime`, and verified by a **positive observation**: `kubectl get leases` now shows
`bootstrap-broker-fence` held by the fence's owner nonce.

**What broke the deadlock is the session's most transferable finding, and it then repeated twice
more.** Two hypotheses were refuted first, one fitting the decoder's own comment and an eight-second
timing window; the cause was named within *one build* of publishing the refusal's reason. Sprint
`2.49` ✅ applied the same move twice again — to the attestation candidate list, and to
`EngineSecretWorkerRefused`, one word for a **twenty-constructor** payload — and each time the cause
was readable on the first run afterwards. **Four consecutive successes make this a method rather than
a series of incidents**: this codebase's fail-closed refusals are correct and mute, and making one
speak has produced the next diagnosis within a build, every time.

**Sprint `2.49` also fixed a defect Sprint `2.47` introduced that only became reachable once `2.48`
landed.** `2.47`'s live proof retired six fence generations, every one against
`BootstrapLeaseMissing` — because the Lease had never been creatable. Once it was, an ordering hazard
in `2.47`'s own code (sampling the clock before the observation, when an expired Lease is encoded as
a deadline *at* the observation instant) made a Lease expired 1h44m earlier read as live, and the
host wedged again. Nothing `2.47` claimed was false; **a live proof is only as strong as the states it
actually reached**, and that arm did not exist yet.

**Sprint `2.50` 📋 is Sprint `2.47`'s title with one word changed**, which is the session's closing
finding. The bring-up now refuses at `StoredRequestBindingMismatch`: a durable secret-worker
checkpoint sits in the preserved `.data/` tree beside the fence, written by the first run that ever
got past the Lease, and two of the seven fields its binding is compared on are freshly minted on
every acquisition by construction. Same tree, same preservation rationale, same consequence — but
**not the same decision**, because a fence is an exclusion record and a checkpoint is a result
record.

**The remedy was already in the tree, had zero callers, and could not be called.**
`decideBootstrapFenceRetire` requires three independent facts and refuses closed on ambiguity in each
— stricter than all three options the ledger row proposed — and its store half was fully wired. What
kept it unwired was structural rather than incidental: the cleanup observation it consumes was bound
to a seven-field worker binding, and a durable fence carries **three** of those seven, so a successor
holding only a stale fence could never construct one. The fix observes worker absence by the one
identity the fence does carry, and the sprint's own Haddock states what that does **not** prove —
Pod absence is not Vault-session absence — together with why it need not: every Vault effect re-reads
the exact fence immediately before acting, so **retiring the fence is the revocation**, and a
survivor fails closed at its next effect.

**Seven prescribed remedies were refuted by measurement across that row's life, and the pattern
outlived every individual finding.** Two were the row's, two were the sprint's own, and three were
found while closing it — including one that would have made the fix *worse* rather than merely
redundant (the label it proposed to select on also matches the Broker's own controller Pod), and one
where "every construction site including the fakes must supply the new field" was reduced by a single
grep to one field and one site, with no fakes in the tree at all. That is the same lesson this plan
recorded about counts on 2026-08-13, arriving at a different surface: **an estimate stated in prose is
not a measurement, and the difference is a command away.**

**A `dev check` regression was found and corrected under Standard C, and it is the kind a test run
cannot catch.** Sprint `4.82`'s recorded evidence includes `dev check` exit 0; it did not reproduce
on this worktree. `4.82` added `cascadePhaseDerivedFrom` to `CascadePhaseOutcome` and updated its own
test block, while a Sprint-`4.76` block in `test/unit/Main.hs` still built the record as a literal —
`-Wmissing-fields`, which only `dev check`'s `-Werror` build promotes to an error. Corrected in place
through the smart constructor `4.82` added for that exact shape. **`test unit` passing is not `dev
check` passing, and an evidence line naming both must have run both.**

**Two more Standard-C corrections of the same family landed with it, and the third recurrence is what
makes it structural.** Phase `2`'s header still led with the 2026-08-10 reopen while every sprint in
that file read `✅` and this document had recorded the reclose on `2.45` since 2026-08-13 — the
precise failure that header was corrected for on 2026-08-08. Sweeping the other eight phase documents
for the same shape found Phase `3` in the identical state: leading with the `🔄 Reopened 2026-08-10 on
Sprint 3.34` paragraph while all 37 of its sprints read `✅` and this document had recorded the
reclose on `3.36`/`3.37` since 2026-08-13. Three recurrences in one family is a structural signal, not
carelessness: **the phase-document header is the only place in the plan where a reclose must be
written by hand in a second location, so it is the one place that drifts.** Both are corrected in
place with the recurrence recorded rather than the paragraph quietly moved. The remaining seven phase
headers were checked in the same sweep and agree with this document.

**Previously (2026-08-14 — Phase `4` reopens and recloses on its own surface the same day;
the ledger's oldest unowned row gains an owner; every other phase stays closed).** Sprints `4.81` ✅
and `4.82` ✅ close a doctrine gap, and Sprint `2.47` 🔄 registers — and part-lands — a sprint this plan
had been **citing since 2026-08-13 without ever writing**. Ledger counts across the day: **pending 65 → 68 →
65, unowned 3 → 2, completed 292 → 295** — the pending total returns to where it started because
every row this entry opened is also closed by it, and the opening figures are themselves a
correction, below. Nothing is retracted: no sprint is un-Done, no qualification row moves, and Phase
`4`'s three prior reclosures stand. Evidence: `dev check` exit 0, `test unit` exit 0 at main Hspec
**3444** plus 27, 33, and 27, and `test integration cli` **57/57**. One Standard-O live proof stays
pending and does not gate closure — `4.82`'s inverse-of-`4.76` reproduction against a stopped API
server.

**This entry is not opened by a failure. It is opened by a rule.**
[chaos_hardening_doctrine.md § 24](../documents/engineering/chaos_hardening_doctrine.md) — *an
observation has a layer*, added by Sprint `0.26` — requires that a derived value be enforced at the
layer its source object is authoritative for, and that a derivation **name the layer whenever it
names the source**. `Prodbox.Lifecycle.ResidueStatus.ResidueStatus` has no field in which to name
one, and it is the common target of every residue observation in the tree.
[Standard L](development_plan_standards.md#l-cli-doctrine-alignment) settles what follows: "when the
doctrine prescribes a behavior that the implemented worktree does not yet honor, the gap is scheduled
through a new sprint … **closing the gap silently without a sprint block is forbidden.**" So this is
scheduled work, not a discretionary cleanup.

**The measurement is what makes it a sprint rather than an opinion: nineteen producers, one
three-constructor type.** Enumerated by signature over `src/`, they read the Pulumi checkpoint store,
AWS resource presence, AWS IAM, AWS EBS, config text, a Pulsar topic, a Vault gate decision, an
object-store listing, SES consumer quiescence, and public-edge TLS — plus an aggregate fold and a
bare transport-failure constructor, which are not observations at all. All land in `ResidueStatus`,
which records none of it. **The defining module states the rule and erases it ten lines later**:
`PresenceObservation` and `CheckpointObservation` are documented there as "deliberately independent …
live resources and a usable encrypted checkpoint are separate external facts", and two production
conversions join them into the same flat type, after which nothing distinguishes them.

**One number in this entry was withdrawn before it was published, and the reason is the entry's own
subject.** A draft said "eleven layers". Nineteen is mechanical — a signature grep. Eleven was not:
it counted table rows, and EBS and IAM are both AWS while a fold and a failure constructor are
neither observations nor layers. A numeral whose derivation is a bucketing choice is a restated
inventory wearing a derived one's clothes, which is precisely the defect corrected two paragraphs
below. The list is falsifiable; the count was not, so the list is what is published.

**The consequence has been sitting in this document's own prose since 2026-08-11 with no owner.** The
2026-08-11 entry wrote that the per-run residue query "observes the in-cluster Authority, which is
authoritative for *what checkpoints this cluster holds*, and the answer is consumed as *do these AWS
resources exist* — a question only AWS can answer, with an admin credential the same command already
holds and never uses for it." That sentence names a § 24 defect exactly, and no sprint was opened
against it; Sprint `4.76`'s own Remaining Work said "none on the code-owned surface". **Registering an
observation as prose is not registering it as work** — which is the same failure mode as stating a
count instead of deriving one, one document up.

**The obvious remedy is forbidden, and finding that out is worth more than the sprint's first
deliverable.** A phantom or GADT layer index on `ResidueStatus` is precisely what
[chaos_hardening_doctrine.md § 21](../documents/engineering/chaos_hardening_doctrine.md) prohibits, in
a sentence that names this surface explicitly: "externally-authoritative state — readiness, leases,
provider state, ownership, **residue** — stays a flat exhaustive ADT computed by pure projection …
the proof belongs in the compile or decode gate, never as an index on an observed value." So `4.81`
is scoped before it starts: the layer is a **field**, and the guarantee is a class-A opaque minter
plus a `dev check` boundary in the `RoundTripWitness`/`TargetSinkVersion` idiom. § 24's anti-dedup
rule binds it too — *say which layer a value is for, do not reduce the count of values* — so the two
observation types are **not** merged. And no § 25 is added: § 24 already prescribes the behaviour and
§ 12 already carries its strength row, so inventing a coordinate for an existing rule would be the
"n+1-th opaque wrapper" move § 23 warns against.

**`4.82` was the half that changes behaviour, and the command already contained the answer it refused
to use.** On an installed-but-not-serving cluster the cascade asks the dead in-cluster Authority for
per-run residue, fails `confirm-MinIO`, and — because a non-observation infers `SubstrateAws` — fails
the drain too: one unobservable cause, two failed phases. In the *same run*,
`runCascadePostflightTagSweep` reaches the real AWS Tagging API and reports `clean`, an authoritative
positive observation at exactly the layer the question is consumed at, using a credential the command
already loaded. `4.82`'s acceptance criterion is the **inverse of Sprint `4.76`'s live run**: identical
host state, exit **0**, with the narration naming AWS rather than the Authority — and a second run
with live per-run state proving the refusal arm still refuses, because the permissive branch alone
proves nothing.

**Sprint `2.47` existed in citations before it existed as a sprint.** The unowned bootstrap-fence
ledger row said "Sprint `2.47` then named the exact arm", and `grep -rn "^## Sprint 2.47"` over the
whole plan returned nothing; Sprint `2.46`'s Remaining Work had likewise deferred the defect to a
follow-up that was never written. The row stayed unowned by accident rather than by decision. **Its
prediction has now been confirmed**: it closed by saying "the next failed run will re-poison the host
identically", and a fence object dated `2026-08-13 23:06` sits on the operator host, written after
that day's hand-clearing by a later abandoned bring-up and preserved intact by the `--cascade` that
followed. A second reproduction for the cost of one `find`. `2.47` adopts the row's framing rather
than re-deciding it — **closing this is a design decision, not a patch** — and Phase `2` stays ✅
closed, because registering an owner is not a reopen (Standard N).

**The ledger counts were restated rather than derived, in the entry immediately after the one that
published the derivation to prevent exactly that.** The 2026-08-13 fourth ledger entry recorded
`pending 67 → 66, unowned 5 → 4, completed 290 → 291`. Run against the table as it stood, the
documented command yields **65 / 3 / 292** — all three off by one. The 2026-08-13 second entry had
named *stating an inventory in prose instead of deriving one* as this plan's recurring defect and
published the one-line derivation so the next figure would be reproducible; the next figure was
restated anyway. Corrected in place under Standard C in
[legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md), with the lesson recorded rather
than the number quietly swapped: **publishing a derivation does not make a count derived — running it
does.** This document no longer carries its own copy of the figures.

**Three further disagreements between documents were found and fixed in the same pass**, none of them
load-bearing on their own and all of them Standard-J: Phase `4`'s own header still claimed "Reclosed
2026-08-10 on Sprints `4.73`–`4.75`" while this document's phase table said `4.78`/`4.79`/`4.80`;
`CLAUDE.md` described the host CLI as binding "the root Vault token", which
[config_doctrine.md](../documents/engineering/config_doctrine.md) and
[vault_doctrine.md](../documents/engineering/vault_doctrine.md) both explicitly deny and which
`loadReadyVaultRootToken` — a stub returning `Left`, with zero call sites — makes false in code; and
`--cascade`'s help text still promises "the K8s drain phase skips gracefully when no cluster is
reachable", which Sprint `4.76` ended and `4.82` will change again.

**Previous head state (2026-08-13, third entry — Phase `3` reopens and recloses on Sprints `3.36` and
`3.37`; every phase stays closed).** Both were found by the **first live Standard-P qualification
run**, and that is the entry's headline: the campaign found two real defects on its first attempt, in
a place no unit or integration suite reaches. Ledger counts across the day: **pending 64 → 66, unowned 2 → 4**. Three rows were added and one
closed; two of the three additions were opened by the campaign itself, not by a sprint.

**A deterministic bring-up failure had been sitting behind a coincidence.** `prodbox test all
--substrate home-local` failed twice identically at the cert-manager mirror. The mirror publication
path never passed a platform to `docker pull`/`docker push`, so under Docker's containerd image store
it published the whole manifest **index**; for a multi-architecture upstream that index names
platforms whose blobs were never fetched. It had never surfaced because **every mirror target that had
published before it presents a single platform** — 17 of the registry's 24 entries — so the index
case had never been the one to fail first.
The asymmetry is the finding: the custom-image *build* path beside it has always resolved
`supportedHostArchitecture`, and the mirror path — named `mirrorHostArchitectureTarget` — never
consulted it. Sprint `3.36` fixes that. It first recorded **no successful-publish proof** — every already-published
mirror was short-circuited — and the gap closed on the next run: **seven publications through the new
path, zero failures, across both of its callers** (five cert-manager mirror targets and the custom
`prodbox-runtime` image under two tags), taking the registry catalogue 17 → 23 repositories.

**Sprint `3.37` is a sprint whose entire content is a measurement that exonerates this repository.**
Five hypotheses were tested and discarded before a pin was touched: stale local content (purged and
re-pulled — still fails); multi-architecture in general (`alpine:3.20`, identical index shape —
exports fine); quay.io (`v1.16.1`, same repository — fine); cert-manager (`v1.16.3/4/5`, `v1.17.1` —
all fine); and controller-only (all five `v1.16.2` images fail). A specific upstream release is
unpublishable, and no harness work would have fixed it. The pin moves to `v1.17.1`, which
**invalidates any prior component-image identity** — `certManagerChartVersion` is derived from the
controller tag by design, so the Helm chart moves with it.

**The residual is the one to carry forward.** cert-manager is the only mirrored platform component
with **no fallback source**, where `kube-rbac-proxy` and others carry one. When its single source
broke, the candidate-retry machinery had nowhere to go and the only remedy left was a Standard-P
identity change forced by someone else's defect. Recorded as its own unowned ledger row, with the
measurement that closing it needs a deliberately-broken primary to test against — not a green run.

**Previous head state (2026-08-13, second entry — Phase `1` reopens and recloses on Sprint `1.89`;
every phase stays closed).** The sprint closes the row Sprint `1.88` split and re-scoped that
morning — **the last row in the `Pending Removal` ledger that carried no owning sprint** — and
records two residuals it declined to absorb. Derived from the table rather than restated:
**pending 63 → 64, unowned 1 → 2, completed 289 → 290.**

**The unowned count went 1 → 2 while the last unowned row closed, and that is the honest shape
rather than a regression.** The row that closed was the sole survivor; the two replacing it are
defects Sprint `1.89` found *by doing the work*, and each carries the measurement that made absorbing
it the wrong call. Folding a silent regional default and a provisioning-surface signature change into
a decode-time narrowing would have produced a sprint whose blast radius nobody had measured. The
figure is stated as what it is — a net increase — because the alternative framing available here
("the last unowned row is closed") is true of the row and false of the count.

**Sprint `1.89`'s row described one defect and there are two — and the second is the one to read.**
Nine Tier-0 coordinates were *decided and discarded*: `validateLocalConfig` refused a malformed value
and returned `()`, so the parse happened and the proof did not survive it, exactly as Sprint `1.83`
found for the public edge. Five were **never decided at all**, and two of those five are not obscure
corners. `route53.zone_id` — the zone every *home* DNS write uses — was checked only for emptiness,
while the structurally identical `aws_substrate.hosted_zone_id` has been shape-checked on every load
since Sprint `1.81`; the two fields disagreed about what a valid one is, and the less-defended was
the one on the home path. `pulumi_state_backend.region` had no rule **anywhere** while both its
siblings in the same three-field section had one, and it is read straight into an S3 client.

**Two drafts were refused by the repository itself, and both refusals are worth more than the fix.**
The ACME account was first modelled as a pair that must be wholly set or wholly absent — a rule that
refuses `prodbox config generate`'s own output, because `defaultConfigFile` ships the ZeroSSL
directory with an empty contact and every home-only config is therefore half-set by construction. The
halves are not symmetric: the directory has a compiled-in default, the contact is the operator's, and
the account is configured exactly when the contact is. Separately, the new `dev check` rule's first
run flagged a **correct** read, because one module bound the name `config` to both a validated and an
unvalidated config; the fix was to rename the binding, not to weaken the rule. Both are the lesson
Sprints `2.45`, `4.78`, and `5.34` each recorded: the prescribed remedy is a hypothesis until the
tree answers it.

**The wire format does not move, and that was the constraint the shape was chosen to satisfy.** No
Dhall field is retyped and no schema alternative is added, so `prodbox config generate` emits the same
bytes for the same record — including Sprint `0.29`'s witness — and **no Standard-P generated-config
identity change occurs.** What does move is refusal: five coordinates that previously decoded now
refuse a malformed value.

**Previous head state (2026-08-13 — Phases `1`–`5` reopen and reclose on Sprints `1.87`, `1.88`,
`2.45`, `3.35`, `4.78`, `4.79`, `4.80`, and `5.34`; every phase stays closed).** Both continue the `Pending Removal` ledger in phase-numerical order as
own-surface reopens (Standard A). `1.87` closes the re-scoped successor Sprint `1.84` registered
against itself; `1.88` **splits** the Tier-0 narrowed-types row, closing its type-guarantee half and
re-scoping the per-field remainder with three corrected counts. `2.45` closed the Bootstrap-Broker durable-validity row. All eight work the ledger in phase-numerical order as own-surface reopens, and **the unowned count
reaches 1**: **pending 71 → 63, unowned 9 → 1, completed 280 → 289** — the single survivor is the per-field Tier-0 narrowing remainder Sprint `1.88` split off with
corrected counts, kept open deliberately because retyping those fields in Dhall is a Standard-P
generated-config identity change.

**Three sprints found their row's prescribed remedy unavailable or wrong, and measuring first is
what showed it each time.** Sprint `2.45`'s row listed eleven surfaces of which **six already had
real predicates**, and missed the seventh undefended one entirely. Sprint `4.78`'s worked example — a
Vault policy error minting `ResidueAbsent` — was measured **unreachable**, because the sole producer
of that `Either` is a constant `Left` carrying neither marker word; that is what made deleting three
arms on a fail-closed teardown gate behaviour-preserving rather than a gamble. And Sprint `5.34`'s
prescribed symmetric credential check is **not available at all**: it refuses this repository's own
integration fixtures, and those fixtures cannot carry a valid AWS key shape because Sprint `1.75`'s
credential scanner fails the build for any tracked file that does. Two repository rules in direct
opposition; the scanner wins, and the check keeps the half that catches a real transposition.

**Sprint `2.45` removed a predicate that made a refusal constructor unreachable, and its row was
wrong about scope in the direction that matters.** `validValue _ = True` was the validity check on
every durable Bootstrap-Broker read and CAS, so `BootstrapStoreCorrupt` could not be produced for
the payloads passing through it. The row listed eleven surfaces and called them "nine payload
types"; **six** already had real predicates, and it **missed** the seventh undefended one — the
durable storage-generation binding every other payload's binding is checked against. Measured: 7
types, 20 sites. That correction is what made the fix one rule rather than seven inventions: these
records are read back through CBOR, which reconstructs fields positionally and bypasses every smart
constructor they are otherwise built through, so each predicate re-runs exactly those. The bypass is
reproduced in a unit case rather than assumed. **It moves a Standard-P persistence-protocol
surface** — no wire format changes, but a read that previously returned a semantically-wrong record
now refuses.

**Sprint `1.88` gave `ValidatedSettings` one production constructor, and measuring first is why it
was closable at all.** Its row read as though the exported constructor were a diffuse risk across
the tree; there were exactly **three** constructor applications in the whole repository —
`validateConfig`, one production forge, and one test fixture. The forge was
`defaultResourceStatusSettings`, which built a record no validation had produced so it could call a
function reading two of its four fields, and obtained its resource plan by `error`-ing on failure.
It was **deleted rather than guarded** — the status reader now takes the two fields it reads — and
two `error` calls left a live `prodbox cluster status` path with it. `checkValidatedSettingsMinter`
keeps the seam closed, keying on field *assignment* so a record update is caught by the same rule.
The bound is stated as what it is: a compiled rule over a source region, not a property of the type.
Its row was also wrong about all three of its own counts — 30/40/74 recorded against 27/18/56
measured.

**The pending total is corrected here, and the correction is this pass's smallest and most
characteristic finding.** The 2026-08-12 entry recorded `73 → 66 pending`; counted from the table
itself the figure was **78 → 71**. The `unowned` count in that entry (16 → 9) is exact and the
completed count (272 → 280) is exact — only the total was wrong, by five. It is the defect class the
same pass named three times in one day: *stating an inventory in prose instead of deriving one.*
[legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md) now carries the one-line
derivation beside the count so the next figure is reproducible rather than restated.

**Sprint `1.87` is the third row in four passes whose prescribed remedy was measured and improved
on, and the first where the improvement was free.** The row said "hand the pure renderer a `String`"
— which leaves `""` a well-typed inhabitant of the renderer's host argument, so the refusal would
have lived in caller discipline, exactly the property Sprint `1.84` already had and recorded as
insufficient. Handing it the `ValidatedServedHost` that `validateConfig` already builds makes
`https:///path` **unconstructible** rather than refused, because that type carries an `Fqdn` minted
only by `mkFqdn`. The cost was zero: the deleted accessor's whole body was `maybe "" servedHostString`
over that same value.

**Its row was also wrong about the shape of the work, and that correction is worth more than the
fix.** It called the sites "pure renderers reached from IO callers", true of the renderers and false
of the frames calling them. Sixteen sites (11 + 5 across two functions, against a combined estimate
of ~10) resolve at **eight** points that already held a `failWith` or a `Left`, so no error channel
had to be invented — and nine functions stopped taking `ValidatedSettings`/`Substrate` altogether,
since they carried the config only to re-derive a host their caller had already resolved. The
mutation exercise then corrected the sprint's own account in turn: deleting `mkFqdn`'s empty check
does not admit an empty name, because the `< 2 labels` rule rejects it independently. The guarantee
has two anchors, not the one the sprint assumed, and the unit case pins the specific constructor so
either anchor moving stays visible.

**Previous head state (2026-08-12 — Phases `0` and `1` reopen and reclose on Sprints `0.27`, `0.28`,
`0.29`, `1.84`, `1.85`, `1.86`, and `2.44`; every phase stays closed).** All seven work the
`Pending Removal` ledger, which is the plan's own stated next axis, in phase-numerical order as
own-surface reopens (Standard A). The unowned count moves **16 → 9** and the pending total
~~**73 → 66**~~ **78 → 71** (corrected 2026-08-13, above): eight rows closed and one re-scoped
successor added, which is why the count falls by seven rather than eight.

**Two rows in this pass had the wrong remedy written into them, and in both cases measuring the
caller is what showed it.** Sprint `1.86`'s prescribed a `Raw*` DTO that cascades into two large
generically-derived records; Sprint `2.44`'s said "returns success when stability was not observed",
which read literally means make it fail — but the function is a *sampler* invoked ten times across a
suite run, and failing it would abort every run before the gate that owns the verdict was reached.
The two folds are right to disagree; what was wrong is that the sampler disagreed **silently**, so a
sample that observed non-stability was indistinguishable from one that observed stability.

**Sprint `1.86` declined the shape its own row prescribed, and measuring first is why.** The row
called for a `Raw*` DTO decoded then narrowed — the pattern two other modules already use. Measured,
that cascades: the decoded field lives on `ProdboxParameters` and `ConfigFile`, both of which derive
`FromDhall` generically over the whole record, so removing one instance forces a parallel `Raw`
record for each of them. A **validating decoder** reaches the same seam with none of that cascade and
is strictly stronger than the DTO, because a DTO leaves a window in which the unchecked value exists
and this leaves none. `Dhall.auto` is no longer a second constructor — it is the same one.

**Sprint `1.85` closed two rows whose common shape is a description contradicting what it
describes.** `certDnsNamesForServedHost`'s Haddock implied a production role Sprint `1.83` had taken
away, and `--yes` on the four stack-destroy verbs still read "Skip confirmation prompts" where
Sprint `4.77` had made the flag *be* the confirmation on a command with no prompt. Neither was closed
by deletion: the contract function is **kept and made load-bearing** — it now pins the carried
certificate scope set against its own derivation, which is the provenance property `1.83`
established and the only place that agreement is stated — and the help text was corrected through a
named constant both the parser and the typed registry read, without touching the parser shared with
verbs that genuinely prompt.

**Three of the four rows were wrong about their own measurements, and that is the pass's finding.**
`0.27`'s overcounted (19/39 recorded, 11/10 measured, plus a 4-sprint category it had no name for);
`0.28`'s undercounted (four env reads recorded, twelve measured); and `1.84`'s was wrong in **both
directions at once** — it estimated "roughly a dozen pure manifest renderers with no error channel"
and recorded that as *measured by attempting it*, where the truth is six direct sites, four already
in `IO ExitCode`, only two pure, and the real ten-site cascade sitting behind a different function
the row folded into the same count. Every one of these came from stating an inventory in prose
instead of deriving it.

**Sprint `0.29` is the one to read, because the fix is a field rather than a gate — and it is this
pass's one Standard-P move.** Sprint `0.24`'s Tier-0 drift gate could not catch a hand edit to a
config primitive that round-trips unchanged, and its own mutation exercise proved no text comparison
could: a re-typed `route53.zone_id` decodes to that value and re-renders to that value, so the edited
file *is* the generator's output for the record it carries. `renderProjectConfigDhall` now stamps
`witness = [ "prodbox-tier0-witness-v1:<sha256>" ]` over the canonical rendering of `parameters` and
`context`, which makes an edited file no longer self-consistent — so the **existing** comparison
catches the class with no second gate. The digest excludes the witness itself, which is forced rather
than chosen (a witness over a record containing itself has no fixed point) and is what makes stamping
idempotent. It changes the content of every generated `prodbox.dhall`, so **a future qualification
run must bind the post-`0.29` generated-config identity** and may not carry one recorded before it;
that consequence is exactly why Sprint `0.24` declined to fold the work in.

**Both rows understated their own defect, in opposite directions, for the same reason.** Sprint
`0.27`'s row recorded 19 `Done` sprints missing `**Implementation**` and 39 missing a docs field;
re-measured across all **359** blocks the figures are **11** and **10**, plus a category the row had
no name for — **4** sprints whose heading is non-standard (`**Implementation** (landed):`) but which
*do* name their paths. The row named Sprint `4.50` as an example, and `4.50` names its paths. Sprint
`0.28`'s row recorded four unguarded `PRODBOX_*` production reads; the measured set is **12**, seven
of which neither the row nor `CLAUDE.md` mentions. Neither error was careless — both came from
stating an inventory in prose instead of deriving one — and both are now derived:
`checkSprintRequiredFields` and `checkProductionEnvVarReads` are registries the worktree must agree
with rather than claims about it.

**The same mistake was available to this pass, and it was made.** The first Standard-H measurement
taken here returned 13/2/10 and put Sprint `1.62` in the *missing* column, for exactly the reason the
original row did: a naive `**Implementation**:` match does not see `**Implementation** (landed):`.
The gate's predicate accepts all three heading forms precisely so a formatting difference can never
again be reported as missing evidence.

**A third instance of an assertion holding a defect in place.** Sprint `0.28` found a unit case
pinning `destructivePlanOptionsArms` to exactly `["Rke2Delete", "NativeNuke"]`, which made the
two-constructor region an invariant while seven destructive constructors dispatched outside it. That
follows the `nuke` sweep absence Sprint `4.76` found and the `gateway-partition` integration
registration Sprint `5.33` removed. `unit_testing_policy.md` canonical statement 11 now names the
class: an absence assertion is an assertion, and must name the doctrine that licenses the absence.

**Both sprints record bounds rather than implying closure.** `0.27`'s gate checks that a field is
*present*, not that its contents are true — binding each sprint to a diff is not possible against
this repository's squashed history. `0.28`'s create-verb allowlist is still an allowlist, and its env
registry proves every read is registered and owned but cannot prove the registered *reasons* true.

**Previous head state (2026-08-11, second entry — Phases `4` and `5` reclose on Sprints
`4.76`/`4.77` and `5.32`/`5.33`; every phase is closed again).** All four sprints registered by the
2026-08-11 MISU audit are ✅ **Done**, on the conditions their reopens existed to remove. The unowned
`Pending Removal` count moves **14 → 16** while the pending total falls **79 → 73**: every row closed
in this pass had an owner, and both rows added are unowned residuals the sprints declined to absorb
with a stated reason rather than a deferral.

**The finding worth carrying forward is that a gate can hold a defect in place as firmly as it can
catch one.** `test/unit/Main.hs`'s legacy-adapter scan listed `discoverClusterTaggedAwsResources`
among the tokens forbidden in `src/Prodbox/CLI/Nuke.hs` — so the absence of the terminal tag sweep
that [lifecycle_reconciliation_doctrine.md](../documents/engineering/lifecycle_reconciliation_doctrine.md)
§ 5 and § 6b have always assigned to `nuke` was an **asserted invariant**, not an omission. Sprint
`4.76` found it only by reading the doctrine against the gate; the case is corrected under Standard C
and now asserts the sweep's presence.

**Sprint `4.76` closed the reported defect and three more that composed with it.** The reported one
was narration: a `--cascade` run printed `no live per-run residue` on an all-`unreachable` input.
Underneath, `inferCascadeSubstrate` tested `isResiduePresent`, so an unreadable backend inferred
`SubstrateHomeLocal` — the one branch on which a skipped drain is success; `clusterReachable :: IO
Bool` returned `False` for *every* non-zero `kubectl` exit, so a refused credential was
indistinguishable from a departed cluster; and the postflight sweep returned `IO ()`, so nothing it
found could reach the exit code. Each is now three-valued, with the uncertain arm as the **default**
rather than as a recognised special case: `ClusterProbe` yields `ClusterAbsent` only for a
recognised connection-establishment phrase and `ClusterUnobservable` otherwise, and a unit case
asserts the closed property that no evidence phrase names an authentication or authorization
refusal — being told `Unauthorized` proves a server answered.

**Its own registration was wrong in one place, and the correction is worth more than the fix.** The
row treated `reconcileAbsent`'s `"Per-run Pulumi destroys"` narration as the cascade's. `prodbox aws
teardown` routes its **`Operational`** batch through the same function, so every operator who has
ever torn down the IAM user was told "Per-run" about it. The label is now derived from the batch's
own `LifecycleClass` and cannot drift from the entries.

**Sprint `4.77` closed two defects where the row named one.** The AWS CLI parses list-valued options
with `store`, so `--tag-filters` passed twice sent only the second — but even both-sent would have
been wrong, because the Tagging API **ANDs** `TagFilters` and the sweep wants either. It is now one
query per filter set, unioned by ARN, with any constituent failure failing the whole discovery. The
EBS reaper gained a client-side re-filter through `partitionEbsTagRows`, which had **no production
caller** — the enforcing-nothing shape Sprints `4.68` and `4.72` also found. `--yes` was resolved by
**gating rather than removal**, because it is the documented automation entrypoint in `CLAUDE.md`
*and* the `resourceDestroyCommand` string the registry prints in teardown refusals; removing it would
have narrowed the automation contract below the doctrine.

**Sprint `5.32` is the one that changes what the plan may claim.** The `LCPC-2026-07-11` reproducer
Standard P depends on now consumes a repository-owned frozen trace whose dispositions are digest-
bound, and a committed mutation fixture makes the command exit non-zero. Both Deployment
Qualification rows were already `pending`, so **nothing is retracted** — but the standing prohibition
lifts: the Counterexample column *may* now be filled by a qualification run, where before it could
not be filled by anything. Sprint `5.33` made `daemon-bootstrap`'s unset arm probe the broker
read-only and refuse when nothing answers, and moved `gateway-partition` out of the integration
surface entirely into the unit suite, which **reduces the canonical suite's node count and reduces no
coverage**.

**A regression was found while validating, and fixed here rather than left.** `prodbox test
integration cli` was failing **8 of 55** before any of this work began: Sprint `3.34` (2026-08-11)
made `endpoints/kubernetes` a live observation and closed on `dev check` + `test unit` evidence
without running the integration suite, and neither fake `kubectl` served it. The failing set was
measured identical before and after the `4.76` code, so no sprint here caused it. Both fake
boundaries now answer.

**Sprint `4.76`'s reproduction was run live, and it is the strongest evidence in this pass.** RKE2
was installed through `prodbox cluster reconcile` and its API server stopped, giving exactly the
reported scenario. `prodbox cluster delete --cascade --yes` reported per-run state as **unobserved**,
printed `no live per-run residue` **zero** times, exited **1** naming `Unresolved phase(s):
confirm-MinIO, drain`, and still ran the drain, reaper, uninstall, and sweep — RKE2 is uninstalled
and `.data/` preserved. The run also exhibited the composing chain that unit cases can only show
piecewise: three `unreachable` statuses now infer `substrate=aws`, so the drain attempted AWS
kubeconfig materialization and failed, where the pre-`4.76` predicate would have inferred
`SubstrateHomeLocal` — the branch on which a skipped drain is success — and the identical host state
would have exited **0**. Two behaviours no fixture exercises were confirmed at the same time: the
postflight sweep reached the real AWS Tagging API, carved out the retained
`prodbox-pulumi-state-long-lived` bucket by design, and reported clean; and the mode-aware notice
closed a `--cascade` run without advising the operator to run `--cascade`.

Evidence: `prodbox dev check` exit 0, `prodbox dev docs check` exit 0, `prodbox dev lint docs` exit
0, `prodbox test unit` exit 0 at main Hspec **3374/3374** (the four sprints add 42) plus 27/27,
33/33, and 27/27, and installed `prodbox test integration cli` **57/57** and `env` exit 0, plus the
live `--cascade` reproduction above. One Standard-O live proof stays pending and does not gate
closure: the `5.33` daemon-bootstrap route-surface probe against a **serving** broker — only its
refusal branch, which is the branch the sprint exists to create, has been exercised.

**Previous head state (2026-08-11, first entry — Phases `4` and `5` reopen on their own surfaces; a lifecycle
narration defect turns out to share a shape with three suite validations that cannot fail).** An
operator `prodbox cluster delete --cascade --yes` run on a host with RKE2 installed but not serving
printed `Per-run residue status: … unreachable` for all three per-run stacks and then
`Per-run Pulumi destroys: skipped (no live per-run residue).`, and exited 0. Three non-observations
were narrated as an observed absence — the inverse of what §§ 3 and 5b of
[lifecycle_reconciliation_doctrine.md](../documents/engineering/lifecycle_reconciliation_doctrine.md)
require, the former of which is titled *Cleanup continues without lying*.

**The narration was the visible half.** Reading the surrounding folds found four more conversions of
the same kind on the destructive path, and an audit of the wider tree found the shape is **not**
general: the ADT layer is sound — ~45 observation-shaped types were enumerated and nearly all give
their uncertain constructor its own arm — but the *producers* one hop upstream collapse it, in
`IO Bool` probes and `String -> Bool` prose sniffers that decide which constructor to mint. This is
[chaos_hardening_doctrine.md § 23](../documents/engineering/chaos_hardening_doctrine.md), which
already names conversions as "where this project's MISU work has actually failed", and § 24's layer
rule: the per-run residue query observes the in-cluster Authority, which is authoritative for *what
checkpoints this cluster holds*, and the answer is consumed as *do these AWS resources exist* — a
question only AWS can answer, with an admin credential the same command already holds and never uses
for it. Phase `4` reopens on its own destructive-path surface: Sprint `4.76` 📋 for the observation
folds and the fail-closed sweep, Sprint `4.77` 📋 for two AWS argv builders that do not send the
filters they name and for an `--yes` flag that confirms nothing.

**The same shape reached the qualification machinery, and that is the more serious half.** Sprint
`5.32` 📋 reopens Phase `5` on the suite content it owns: the `LCPC-2026-07-11` reproducer named by
Standard P discards its frozen-trace argument and asserts what its own generator wrote, so the
mechanism written to keep fake-interpreter evidence *out* of qualification cannot itself fail. Both
Deployment Qualification rows are already `pending`, so **no `proven` claim rests on it and nothing
is retracted** — but the Counterexample column may not be filled until `5.32` lands, and Sprints
`5.19` and `8.12` carry Standard-C corrections saying so. Sprint `5.33` 📋 covers the two remaining
non-falsifying validations. Neither reopen blocks the other, and neither blocks any earlier phase
(Standard N).

**Previous head state (2026-08-10, third entry — Phases `2` and `3` reopen on their own surfaces;
doctrine lands, code is registered, and the AWS-substrate suite is blocked on a chart defect).** A
live `prodbox test all --substrate aws` run failed at the `bootstrap-broker` Helm release on eight
consecutive attempts. The chart's NetworkPolicy permits Kubernetes API egress on TCP `443`;
kube-proxy DNATs the API Service to its endpoint on `6443` before the CNI evaluates egress, so the
rule matches nothing, the broker answers `/healthz` 200 and `/readyz` 503, and
`helm upgrade --wait` expires after thirty minutes. A control test separated the two candidate
causes: pods in namespaces carrying no NetworkPolicy reach `https://10.43.0.1:443/healthz` and are
answered `401`; the policied pod times out.

**The defect is not the digit.** `grep -rn "6443" src/` returns exactly one hit — a kubeconfig
string-match — so the Kubernetes API egress coordinate has no compiled owner anywhere, and with no
owner there is nothing for a restatement to drift from: each of three sites authors its own. The
DNAT fact survives in the repository only as a chart comment, which
[pure_fp_standards.md § 1.4](../documents/engineering/pure_fp_standards.md) already names a defect.

**The doctrine gap is what makes this worth a sprint rather than a fix.** `apiEgress` is the one
place the rule is *generated* from a live observation, and it is wrong in **both** coordinates,
because it observes `service/kubernetes` (pre-DNAT) while the policy is evaluated post-DNAT.
Deriving from one source — [chaos_hardening_doctrine.md § 21](../documents/engineering/chaos_hardening_doctrine.md)'s
class-G, and § 23's one-derived-encoder rule — fixes the encoder count and not the layer. Sprint
`0.26` ✅ **Done** appends § 24, *an observation has a layer*, with the measured worked example and a
§ 12 ledger row; it lands on the already-reclosed Phase `0` documentation surface and neither
recloses nor reopens that phase.

**Two code sprints were registered; one has landed.** Sprint `3.34` 📋 (Phase `3` own-surface
reopen) gives the coordinate one owner derived from `endpoints/kubernetes` — one observation
yielding both post-DNAT halves — and extends the chart lint's region to every repo-owned template.
Sprint `2.42` ✅ **Done** (Phase `2` own-surface reopen, 2026-08-11) stopped the broker discarding
its typed transport failure, which is why the outage cost eight runs to diagnose rather than being
self-evident from the readiness body: all six discarding sites in the Kubernetes boundary now carry
their detail, and `requestKubernetes` classifies the caught `HttpException` onto a closed,
payload-free label set rather than collapsing it. Phase `2` recloses on `2.42`; Phase `3` stays
reopened on `3.34`.

**A claim deliberately not made.** The lint `3.34` adds closes drift between a rendered value and its
compiled owner, not correctness of the owner; with the owner still saying `443` the cluster breaks
identically. Only the live run proves `6443`, and this head state does not credit the gate with an
outage it would not have caught.

The ledger arithmetic: **four rows added, three owned (`3.34` ×2, `2.42` ×1) and one unowned**, so
the unowned count moves **6 → 7**. A second Standard-C correction fell out of the work — the Phase
`3` header still asserted its reclose on Sprint `3.32` and had never recorded `3.33`, which this file
has named as that phase's reclose since 2026-08-09.

**Prior head state (2026-08-10, second entry — every phase is closed; the `Pending Removal`
backlog carries no unowned row on any closed phase's reopened surface, and deployment qualification
remains pending on both substrates).** Sprints `4.73`–`4.75` are ✅ **Done** and **Phase `4`
recloses**, which ends the 2026-08-09 own-surface reopen on the condition it existed to remove: no
`Pending Removal` row on a Phase-`4` surface is unowned. The unowned count moves **9 → 6**, and all
six sit on Phase-`0`, `1`, and `5` surfaces.

The arithmetic is stated exactly rather than rounded: **two unowned rows moved to `Completed`, one
gained an owning sprint and stays open as a Standard-O recorder axis, and no new unowned row was
created by doing the work.**

**Sprint `4.74` is the one to read, because its row was wrong about the defect in the direction that
matters.** The row said a Vault CAS conflict "is not distinguishable from a transport failure at the
caller" — i.e. that callers reported coarsely. Measurement found **four callers already making the
distinction and all four making it wrongly**, with the same two lines: `HttpStatus 400 -> "conflict"`
and a `409` arm Vault never returns for a KV CAS. Vault answers a version mismatch and a malformed or
cas-required request with the same `400`, so `reconcileRetainedAuthorityEpoch` spent an
authority-epoch CAS retry on a request Vault had refused and then reported it as a lost race, and
`vaultRequestReplayRepository` answered `RequestReplayCasConflict` — *another writer already claimed
this request id* — for a write that never happened. That is a replay-protection decision made on a
premise that did not occur. The row also named three files against a measured **eleven call sites across
ten modules** — and the eleventh was found by this sprint's own `dev check` rule on its first run,
not by reading, because it reaches the CAS through a module-local session wrapper.

**Sprint `4.73` corrected its row by finding a consequence the row had not considered.** The row
enumerated three obstacles and all three are answered — two new record types with total owner/type
rules, a propagation barrier that keeps the batch's single wait rather than five in series, and
unchanged sequencing behind `ensureSesDnsInputs`. What the row did not say is that the lane needs
**its own owner**: reusing `AwsLifecycleProviderDnsOwner` would have made `dnsRecordLifecycleClass`
assert `PerRun` about records in the operator's retained parent zone, and would have handed the
public A-record writer TXT/CNAME/MX authority over the same zone.

**Sprint `4.75` takes ownership of the one row that cannot be closed by code, and the reason is a
measurement rather than a deferral.** `dhall/capacity/measured/` holds only `Schema.dhall` — no
measured profile has ever been committed for any lane — so the control-plane profile is downstream of
Sprint `5.21`'s recorder activation, and building the schema field plus certification rule now would
land a mechanism with nothing to certify. What the sprint does land is the correction its row
exposed: `rawServiceTimeMicros`'s own haddock said the field carries a measured value while its only
producer authors it.

**Two guarantees are stated as what they are rather than as what they sound like.** Sprint `4.74`'s
build rule is a compiled rule over a source region, not a property of the type — the transport result
stays `Either HttpError` so the Vault session wrapper can still see a `403` for its single relogin —
and per [chaos_hardening_doctrine.md § 22](../documents/engineering/chaos_hardening_doctrine.md) that
bounds this repository's source, not the Vault protocol. Retyping the primitive across eleven
critical-path sites was considered and declined as the coupled-big-bang shape that required reverting
Sprint `4.51`.

Evidence for `4.73`–`4.75`: `prodbox dev check` exit 0, `prodbox dev docs check` exit 0,
`prodbox dev lint docs` exit 0, `prodbox test unit` exit 0 at main Hspec **3294/3294** (the three
sprints add 7) plus 27/27, 33/33, and 27/27, and installed `prodbox test integration cli`
**55/55**, exit 0.

**Prior head state (2026-08-10 — Phase `4` closes five of the six unowned ledger rows it owned as
Sprints `4.67`–`4.72` and stays 🔄 Active on the sixth; deployment qualification remains pending on
both substrates).** Every other phase is closed. The remaining plan work is still the two named axes
below — the `Pending Removal` ledger (Exit item 33) and then the Standard-P campaign (items 32, 47,
48) — and the unowned count moves **12 → 9**.

The arithmetic is stated exactly rather than rounded: **five unowned rows moved to `Completed`, one
was narrowed and replaced by a smaller row that stays open, and three new unowned rows were created
by doing the work.** All three new rows are residuals the sprints declined to absorb, each with a
measured reason.

**Two of these sprints found that a mechanism the repository already had was enforcing nothing, and
that is the pass's recurring finding.** Sprint `4.68`'s bounded admission machine —
`ServiceCapacityPlan` plus a pure decide/evolve `AdmissionQueue` — has existed since Sprint `1.62`
with **no production consumer on the accept path**. Sprint `4.72` measured the same thing about
`DnsRecordProgram`: before it, `runDnsRecordProgram`, `EnsureDnsRecord`, and `DestroyDnsRecord`
appeared **only in two unit suites**, so the typed DNS program bounded nothing that runs. Both are
the shape Sprint `1.82` closed for the Tier-0 secret guard, and in both cases the honest fix was to
make the existing mechanism load-bearing rather than to write a second one.

**Sprint `4.68` is the one to read, because testing the path found a defect that reasoning about it
had not.** The bounded accept loop's two new replies — `429` when saturated and `408` when the
deadline has passed — are precisely the two produced *without* reading the request, and `close` on a
socket holding unread bytes sends RST, which discards what was already written. That is Sprint
`4.60`'s "accepted a connection and answered nothing" reappearing through the kernel instead of
through a `const`. The fix drains the request through the ordinary bounded reader first. The same
sprint places the deadline **inside** the response obligation rather than around it, because a
`timeout` outside delivers an asynchronous exception that the obligation answers with its
*cancellation* refusal — so the caller would have read `503 shutting-down`, naming the wrong cause,
and any second write would be a second reply on one connection.

**Sprint `4.71` was registered as a `Cardinality` hygiene row and the audit found three real
lost-update races.** `updateParentChildIndex` read the federation child index, upserted one child,
and wrote unconditionally, so two concurrent registrations both read the same index and the second
**silently erased the first child** — and no downstream read-back would notice, because an index is
perfectly well-formed with a child missing from it. The Vault secret bootstrap fold and the two
parent-held child objects had the same shape. The gateway continuity admission marker becomes
create-only because its own contract already said so: "once this marker exists, a missing object is
recovery failure", and a latch that can be overwritten is not a latch.

**Three sprints corrected their own row's measurements.** Sprint `4.67`'s row counted 51 status
projections under `src/Prodbox/ControlPlane/` — exactly right for that namespace and wrong for the
repository, because five more live under `src/Prodbox/Lifecycle/Decommission/` and are reached from
`RoleInterpreters.hs` like any other; the migrated total is **56 across 34 files**. Sprint `4.70`'s
row said the surviving Authority-side minter would have to be constrained; measurement showed the
CAS request needs **no exported constructors at all**, since every non-minting use was the same
three-way projection. Sprint `4.72`'s row said `DnsOwnerAuthority` "says nothing about a caller that
reaches Route 53 directly" — true, and understated, per the measurement above.

**The sixth row is narrowed rather than closed, and the reason is measured rather than asserted.**
`applySesDns` writes three record types where `DnsRecordType` defines two, writes five records in one
batched change with a single propagation wait (a coordinate is one name and one type, so the typed
program turns that into five sequential INSYNC waits on a live AWS path this repository cannot
exercise locally), and derives its desired values from a step that may create the SES identity first,
while the program's ensure requires a conclusive initial observation. That is a redesign of the SES
DNS mutation, not a rerouting of it, so it is registered as its own row and **Phase `4` stays
🔄 Active on it**.

Evidence for `4.67`–`4.72`: `prodbox dev check` exit 0, `prodbox dev docs check` exit 0,
`prodbox dev lint docs` exit 0, `prodbox test unit` exit 0 at main Hspec **3287/3287** (the six
sprints add 12) plus 27/27, 33/33, and 27/27 on the dedicated suites, and installed
`prodbox test integration cli` **55/55**, exit 0.

**Prior head state (2026-08-09, third entry — Phase `4` works its share of the unowned ledger
backlog as Sprints `4.63`–`4.66` and stays 🔄 Active; deployment qualification remains pending on
both substrates).** Every other phase is closed. The remaining plan work is still the two named axes
below — the `Pending Removal` ledger (Exit item 33) and then the Standard-P campaign (items 32, 47,
48) — and the ledger count moves **15 → 12**.

The arithmetic is stated exactly rather than rounded: **three unowned rows moved to `Completed`, one
was struck as stale, one was re-scoped and stays open, and one new unowned row was created by doing
the work.** The new row is the one Sprint `4.64` found while measuring itself: the final AWS-substrate
reconcile slice discards the admission set it returns, which is correct only because it is final.

**Sprint `4.66` is the one to read, because its defect was on the wire.** `httpReasonPhrase` mapped
six statuses while the interpreters emit ten, so the control plane was writing
`HTTP/1.1 403 Status` — a status line naming no reason — for every authorization refusal,
authentication failure, replay expiry, and cleanup tombstone. The ledger row understated it three
separate ways and each count is corrected by measurement: the unmapped set is `{401, 403, 408, 410}`
not `{401, 403}`; **17** emitting sites across 11 files, not nine; **338** producer literals and 75
type sites across 37 files, not 47 and 17. The sprint is honest about stopping short of the row's own
prescription: the closed `ReplyStatus` set, a transport that cannot render outside it, and a
`dev check` rule that fails on drift all landed, but the producers still answer a raw `Int`, so the
row is **narrowed rather than closed**.

**Three rows were wrong about their own evidence, and one would have failed the build if followed.**
Sprint `4.65`'s row prescribed importing `Prodbox.Logging` — a module that has never existed on any
branch — and calling `hPutStrLn stderr`, which `dev check` forbids in every `src/Prodbox/**.hs`
outside three exempt paths; it was also filed against a file that never sees the exception. Sprint
`4.63`'s row named one call site of four and two result constructors of five. Sprint `4.66`'s is
above.

Sprint `4.63` ✅ decides the global target-intent ledger's CAS verdict at all four sites, and the
disposition was **decided rather than copied** from `4.62`: only `ModelBCasRefusedCorrupt` refuses,
because every producer of it refuses *before* the object store, while `ModelBCasUnobservable` stays
deliberately on the read-back path as the applied-but-response-lost case. A second defect fell out —
a refusal used to consume a compaction retry and surface as `TargetCommitCompactionOverBound`, a
capacity bound named as the cause of a refusal. Sprint `4.64` ✅ makes the admission reset Sprint
`4.61` fixed by hand **unnameable**, using the type rather than a lint and reusing the existing
allowlist rather than writing a new rule. Sprint `4.65` ✅ gives a refusal back its structured reason
through a required positional argument, because a defaulted field would have made observation opt-in
and the defect is that nobody opted in.

**One row was closed by being refuted.** The row claiming `prodbox test integration cli` fails 20 of
55 was measured against a baseline Sprint `5.31` had already fixed; the suite passes **55/55, exit 0**
today. It carried an operational warning that the suite "is currently NOT a usable regression gate",
which is exactly the kind of stale claim that stops a gate being run.

Evidence for `4.63`–`4.66`: `prodbox dev check` exit 0, `prodbox test unit` exit 0 at main Hspec
**3275/3275** (the four sprints add 8) plus 27/27, 33/33, and 27/27 on the dedicated suites, and
installed `prodbox test integration cli` **55/55**, exit 0.

**Prior head state (2026-08-09, second entry — Phases `1` and `3` reopen and reclose on their own
surfaces; Phase `4` is 🔄 Active on its own reopen; deployment qualification remains pending on both
substrates).** With every sprint of every phase `Done` at the start of this pass, the remaining plan
work is the
`Pending Removal` backlog in [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md)
(Exit Definition item 33) and the Standard-P qualification campaign (items 32, 47, 48). That backlog
is being worked in phase-numerical order as own-surface reopens under
[Standard A](development_plan_standards.md#a-continuous-clean-room-narrative); seventeen of its rows
carried no owning sprint at all.

Sprints `1.82`, `1.83`, `3.33`, and `4.62` work the first three phases' share of them, and all four
close the same defect shape at different layers — **a value the repository already computed and then
did not use**. The ledger arithmetic is stated exactly rather than rounded to the flattering summary:
**four unowned rows moved to `Completed`, one was re-scoped and stays open, and two new unowned rows
were created by doing the work**, so the count went 17 → **15**.

**Sprint `4.62` is the one to read.** Its ledger row described a hygiene defect — a CAS verdict bound
to `_`, with correctness resting on the read-back that followed — and the mutation exercise showed
that description was too kind. With the fix reverted, `runPreparedTargetCommit` returns
`TargetCommitRunCommitted { targetCommitRunSinkCasAttempted = True }` for a target-secret write the
sink store **explicitly refused**, reachable whenever the sink holds the expected bytes for any other
reason. A refusal became a commit record. It is the only sprint in this pass that moves a Standard-P
surface (persistence protocol), and the only one whose defect was worse than its own registration
said.

Evidence for `1.82`, `1.83`, `3.33`, and `4.62`: `prodbox dev check` exit 0, `prodbox dev docs check`
exit 0, `prodbox dev lint docs` exit 0, `prodbox test unit` exit 0 at main Hspec **3267/3267** (the
four sprints add 12) plus 27/27, 33/33, and 27/27 on the dedicated suites, and installed
`prodbox test integration cli` **55/55**.

Sprint `1.82` ✅ makes the Tier-0 secret-free guard total and load-bearing. `tier0CarriesNoSecretValues`
was exported, was documented as the guard that rejects a record carrying a literal credential, and had
zero production call sites. It is now the last step of `decodeProjectConfigDhall`, the one Tier-0
decode gate, and its enumerator is a positional pattern so a new section carrying a `SecretRef` is a
compile error rather than a silent omission — proven by a mutation exercise. **The overlap the ledger
had estimated is now measured**: `validateAwsCredentialsRef` runs over the decoded `parameters` and
never over this record, so the in-cluster daemon binary context and the Sprint `0.24` drift gate both
reached a full Tier-0 record with no check at all, and `acme.eab_*` had none on any path. The sprint
also corrects a governed-document claim in place rather than quietly making it true:
[vault_doctrine.md § 20.3](../documents/engineering/vault_doctrine.md) stated the discipline was
"enforced today over Tier-0 Dhall by `tier0CarriesNoSecretValues`", which was a claim about call
sites made while there were none.

Sprint `1.83` ✅ carries the parsed public edge instead of re-deriving it.
`validateConfiguredCertScope` built a `CertScopeSet`, bound it to `_`, and returned `()`; eight
production sites then rebuilt it from raw `Text`. `ValidatedSettings` now carries the home served
host and its scope set plus **`Maybe`** the AWS pair, so the empty-string AWS hostname Sprint `1.81`
recorded as its own residual is gone from every caller that has an error channel. The unit case
compares the carried scope set against the derivation it replaced on both substrates, which is what
makes this a provenance change rather than a behaviour change.

**Two residuals were registered rather than absorbed**, and one of them corrects an estimate by
measurement: converting `substratePublicFqdn` to the `Maybe` its own projection now carries cascades
through roughly a dozen **pure manifest renderers** with no error channel — established by attempting
the change, not by inspection — so it is a separate call-site sprint rather than a widening of this
one ([Standard L](development_plan_standards.md#l-cli-doctrine-alignment)).

Evidence for `1.82` and `1.83`: `prodbox dev check` exit 0, `prodbox dev docs check` exit 0,
`prodbox dev lint docs` exit 0, `prodbox test unit` exit 0 at main Hspec **3264/3264** (the reopen
adds 9) plus 27/27, 33/33, and 27/27 on the dedicated suites, and installed
`prodbox test integration cli` **55/55**.

**Prior head state (2026-08-09 — all code-owned phases `0`–`8` are closed again; deployment
qualification remains pending on both substrates).** Sprint `5.31` is ✅ **Done** and Phase `5` is
reclosed on its own surface. The installed integration suites now pass **55/55** across `cli` and
`env`, and the canonical `prodbox test unit` command exits 0 with the main Hspec inventory at
**3255/3255**.

The last four failures were fixture expectations, not unresolved product-design questions. The
fake Kubernetes observation exposed three gateway Pods while the typed capacity projection requires
exactly two, so the stability sampler correctly reset its consecutive-success count to zero. The
transient primary code-server image push retries that same candidate and succeeds, so the fallback
image is correctly never used. The config-setup assertion expected the retired bare-string Dhall
shape instead of the derived union constructor and structural decoded value. The AWS-IAM teardown
case already specified the unavailable authenticated Credential Provisioner refusal; supplying its
fixture with a valid fixture AWS subzone lets the scenario reach and prove that intended refusal.

This closes the code-owned axis only. The current-revision clean-room home and AWS deployment
qualification campaigns remain `pending` under Standards O/P, so the repository still makes no
deployment-ready, seamless, or operational-cutover claim.

**Prior head state (2026-08-08, second entry — the doctrine is corrected; Phases `4` and `5`
reopen on their own surfaces for the code).** An investigation into 20 of 55 failing
`prodbox test integration cli` / `env` cases found a **MISU failure**, not a missing MISU move.
Sprint `1.80` had retyped `deployment.public_edge_advertisement_mode` into a closed Dhall union —
precisely the class-D move `chaos_hardening_doctrine.md` § 21 prescribes, on the field § 21 names as
its own worked example — and applying it broke twenty cases whose fixtures hand-authored the old
shape, surfacing as `NoResponseDataReceived`: a transport error naming nothing. Five
minting-boundary gates, a Ring-1 `assert`, a Ring-2 decode gate and the Sprint `0.24` drift gate
were all in force and none fired, because each constrains what a value can be *inside* a region and
the defect lived at three conversions out of one.

Two corpus claims were therefore incomplete, and governance Sprint `0.25` corrects both on the
already-reclosed Phase 0 documentation surface (**no reclose event**, as with `0.18`–`0.24`):
`chaos_hardening_doctrine.md` gains **§ 23, "Conversions — where the moves stop"** — *a typed value
crossing out of a region must be reconstructed by exactly one derived encoder, or the region's
proofs end at the crossing* — and **§ 2C of `resource_scaling_doctrine.md` gains "The region of
Ring 2"**: a ring is a property of a type over a *compiled region*, and `prodbox dev check`'s
`cabal build … all` resolved to `lib` and `exe:prodbox` with **no test suite**, so for `test/` —
where every sprint's evidence lives — this repository sat at Ring 0 while recording Ring-2 claims.
(Sprint `5.30` ✅ later closed that region gap by adding `--enable-tests`; the § 2C measurement is
restated there, not here.)
Sprint `0.25` also corrects § 21's "Neither needs new doctrine" in place: the table was right about
the coordinate and wrong about the sufficiency.

**Phases `4` and `5` reopened on their own surfaces** (Standard A) to land the code. Sprint `4.60`
✅ gives the control-plane server a response obligation, so "accepted a connection and answered
nothing" stops being expressible; the Bootstrap Broker has held that standard since `2.33`. Sprint
`5.30` ✅ reduces four hand-written Tier-0 encoders to the one canonical generator, keeps the
fixture decode failure a typed value, and adds `--enable-tests` so something compiles the evidence
surface — neither half alone would have caught `1.80`. Neither moves a Standard-P
production-composition surface.

**Phase `5` stays 🔄 Active on Sprint `5.31`, and that is the honest state rather than a
rounding-up.** The integration suite went **20 of 55 failing → 8 → 4** across `5.30` and `5.31`.

Sprint `5.31` is worth reading as a chain, because each link was invisible until the one above it
was fixed. `runAnchoredStepOrder` ended in `refuse _ = ExitFailure 1` — a typed `AdmissionRefusal`
discarded with a wildcard, on a path that printed nothing, so a refused reconcile exited 1 in
silence. That is § 23 at the *step* boundary: `ExitCode` carries one bit and has no room for a
reason, and `renderAdmissionRefusal` already existed and was already exported — the crossing simply
did not use it. Returning the refusal instead of lowering it makes the silent version
**unrepresentable rather than merely absent**. Making it speak then produced the real defect in one
run, and it was a production one: **Sprint `4.61`**, admissions reset at every phase boundary, so
every cross-phase graph dependency was refused unconditionally. Underneath that were three further
fixture drifts, ending in the capacity drift Phase 5 had registered as "currently silent" — the fake
LimitRange declared the gateway at 250m where the plan projects 750m. The fixture's observed cluster
state is now *rendered from* the projection the validator compares against, so that class cannot
recur.

The four remaining cases are no longer one defect; each is a distinct named question, and one of
them (`aws-iam credential teardown`) needs a decision rather than an edit — it asserts a refusal that
a fixture fix on the way in removed. Recorded rather than resolved by whichever change makes it
green.

**A claim in `5.30`'s own registration was corrected against the mutation that tested it**
(Standard C). It asked that "adding a field to `DeploymentSection` must fail the build, not a test",
unqualified. The mutation showed a field *addition* is rendered automatically by the derived
encoder — a compile error only where a fixture constructs the record explicitly — while a *retype or
removal* is a compile error everywhere. The property that matters holds on both paths (no schema
change reaches a fixture as a runtime decode failure), but the registered claim was stronger than
the mechanism delivers and is now stated as the mechanism actually behaves.

Evidence for `0.25`: `prodbox dev docs check`, `prodbox dev lint docs`, and `prodbox dev check` all
exit 0. Evidence for `4.60` and `5.30`: `prodbox dev check` exit 0 **with `--enable-tests` in
force**, so the eight test suites are type-checked by the canonical gate for the first time;
`prodbox test unit` 3253/3253.

**Prior head state (2026-08-08 — all code-owned phases `0`–`8` are closed again; deployment
qualification remains pending on both substrates).** The 2026-08-05 own-surface reopens of Phases
`3`, `4`, and `5` are all closed: Sprint `3.32` (caller-bound DNS ownership authority), `4.55`
(control-plane readiness as `STM`-typed cached facts, old seam deleted), `4.56` (the admission proof
threaded to the mutating act), `4.59` (the superseded in-controller Target write lane deleted), and
`5.29` (DNS01 challenge registration, always-run deletion, exact absence read-back). Evidence:
`prodbox dev check` exit 0, `prodbox dev docs check` exit 0, `prodbox dev lint docs` exit 0, and
`prodbox test unit` exit 0 — 3233/3233 plus the dedicated 27/27 admission, 33/33 authentication, and
27/27 transport suites.

**Four sprint premises were false against source and were corrected rather than worked as written**
(Standard C). `3.32` had the `pguser` ownership direction backwards — prodbox generates the Patroni
passwords into Vault and one chart-local mirror runs Vault → Secret, with no reverse path — and its
own earlier correction's claim that "no process copies the value" was also false. `4.55` mis-stated
its backend-call counts for all five roles, and the two it said ran nothing were the worst offenders.
`4.59` named two deletions that source refuses. `5.29` asked for a registration that cannot be built
as specified, because prodbox does not write the record and the Challenge UID does not exist yet. In
each case the corrected finding is recorded in the sprint block rather than the sprint being marked
done against a false premise.

**Prior head state (2026-08-03 — all code-owned phases `0`–`8` are closed; deployment
qualification remains pending on both substrates).** Sprints `0.19` and `0.20` add repository secret
hygiene and then repository value hygiene as governance additions on Phase 0's already-reclosed
documentation surface (no further reclose event), with own-surface reopens on Phases `1`, `5`, and
`7` landing the remediation each owns. `vault_doctrine.md` §20 now requires every committed value
that stands in for real-world data to be officially synthetic, unmistakably synthetic, or genuinely
real and declared as such in place — the rule the seven-commit hosted-zone-id disclosure exposed as
missing. Prior head state (2026-08-02): Sprint `8.12` closes the non-partial
eight-assertion, 23-fault invite qualification artifact and installed counterexample projection
(invite 8/8, daemon lifecycle 27/27, unit 3067/3067, installed integration 55/55 twice, `dev check`
exit 0). Sprint `8.11` closes the
revisioned SES aggregate, exclusive credential-writer migration, exact checkpoint GC, durable
target delivery, and role-separated convergent interpreters (unit 3059/3059, installed integration
55/55 twice, `dev check` exit 0). Sprint `7.33` closes AWS control-plane
role/transport isolation, deterministic IAM names, the pure controller-transition algebra,
target-local DNS01, registered public-A reconciliation, and the code-local fault model (unit
3040/3040, installed integration 55/55 twice, `dev check` exit 0). It does not production-wire
owner-UID/child-ARN registration or provider-family cleanup, which the later Sprint `7.36` owns.
Sprint `6.4` closes the versioned clean-room
cutover/restore/cleanup trace, exact-prefix restart matrix, rollback-before-mutation refusal, and
installed-binary legacy-residue scan (focused 8/8, unit 3028/3028, `dev check` exit 0). Sprint
`5.22` closes the exact certificate-scope
serving validation after Sprints `5.18`/`5.19`/`5.21`: the named installed-binary command, exact
presented-SAN oracle, typed OpenSSL prerequisite, restore-vs-reissue proof, and canonical-suite
registration are code-locally complete (unit `3018/3018`; installed CLI proof passed). Live serving,
calibration, and aggregate evidence remain non-blocking Standard-O/P qualification axes. Sprint
`4.50` closes the in-cluster retained-authority clients,
five-role runtime, Target/Provider/Credential execution, native SES/Route53 reconciliation, exact
TLS retention, clean-install backup admission, legacy transport deletion, and crash-safe
decommission. Encrypted short-lived EKS client authentication replaces host-projected AWS
credentials across kubectl/Helm/drain/monitor callers. Sprint `4.53` additionally replaces the
shallow port probe with an authenticated S3 endpoint witness. Closure evidence is warning-clean
builds, `prodbox dev check` exit 0, and `prodbox test unit` exit 0 (2972/2972 plus the dedicated
27/27 admission, 33/33 authentication, and 27/27 transport suites).
The prior formatter, nested-case, subprocess/output, opaque secret-payload, chart-label, and stale
retained-authority fixture blockers are closed rather than waived. Work now proceeds in numerical
order through Phase `7`. Deployment qualification remains a separate Standard-P axis and cannot
excuse missing production code under Standard O. Prior head state
(2026-07-30 — typed three-valued readiness
doctrine adopted; Phases 4 & 5 reopened,
Sprint `5.25` Active; Sprint `4.53` is now Done).** The two "transient blips" from the live cold `test all` (a gateway
stability sample latching a not-yet-scraped healthy Pod; a host-direct object-store/lease read
collapsing a transient MinIO-endpoint connection-refused into terminal authority-loss) are one defect
class — a *not-yet-ready* observation collapsed into a *definitively-fatal* bucket (the **bring-up
dual**). The fix makes each unrepresentable by giving the not-yet-ready state a distinct non-terminal
constructor, reusing the repo's three-valued readiness model, build-enforced by a new
`readinessObservationViolations` conformance gate. **Sprint `5.25`** (supersedes `5.24`) splits the
gateway-stability observation type; **Sprint `4.53`** adds `ModelBEndpointUnready` /
`LeaseAuthorityEndpointUnready` with a fencing-safe lease-monitor retry; its Phase-2 authenticated
S3 deep-probe witness is now also landed. Doctrine codified in
`bootstrap_readiness_doctrine.md` §0.9/§1/§2.4. Code-owned and validated: `dev check` 0, Sprint 5.16
18/18, host-direct adapter 14/14, lease monitor safety suites. Deployment qualification stays pending
(harness/failure-classification fixes; no production-composition change). Prior head state (2026-07-30 —
Phase `5` reclosed on Sprint `5.24`, the restore-time gateway observability wait; now superseded by
Sprint `5.25`): Sprint `5.24` is an own-surface Phase-5 reopen (Standard A) that fixes a
live-surfaced harness defect: the restore-cycle gateway stability sample failed closed on a
freshly-(re)started but healthy gateway Pod whose working-set metrics-server had not yet scraped
(`sampled_high_water_bytes=unobservable`, `restart_delta=0`, Pod at 39–78 MiB). The sample now runs a
read-only, non-latching observability wait (`awaitGatewayRuntimeObservable`) before recording, with a
new pure transient-vs-fatal `gatewayStabilityUnreachableIsTransient` classifier; the absorbing
classifier is unchanged, so a genuine OOM/restart/over-threshold still fails closed immediately.
Code-owned and validated (`dev check` 0, Sprint 5.16 suite 18/18). Proven live on a clean cold home
`prodbox test all`: `RestoreNodeReconcileChart RestoreChartGateway -> succeeded` (the exact node that
failed with `MemoryReadingUnobservable` pre-fix), unblocking the whole downstream restore graph
(vscode/api/websocket reconcile + WaitForPublicEdge all succeeded), with zero stability failures and
`0` gateway restarts across the run; the only failed restore node was the unrelated transient
MinIO-NodePort blip in `RestoreNodePrepareRetainedSes`. A full green run through Phase 2 additionally
depends on that transient object-store class and the genuine heap-leak holding off (cutover) — neither
this sprint's surface. Deployment qualification stays pending. Prior head state (2026-07-30 — Phase `2` reclosed on
Sprint `2.37`, the non-constructible emitter retained-assertion bound): Sprint `2.37` is an own-surface
Phase-2 reopen (Standard A)
that closes the retained-assertion (unacked-suffix) memory-leak class behind the 2026-07-29 live
gateway OOM: the Sprint-`2.32` cutover-target `JournalLeaseEmitter` kernel now grows its retained
unacknowledged suffix through a hidden-constructor `BoundedUnackedSuffix` that fails closed at the
existing `retained_assertion_capacity` ceiling (over-retention is non-constructible), and a failed
checkpoint signature re-emits its exact compaction so a stalled signer cannot wedge the suffix. The
durable projection is unchanged (byte-compatible); code-owned and validated (`dev check` 0, emitter
suites 121/121 + 65/65). A live long-run leak-free proof of the target emitter remains the
non-blocking Standard-O axis, and deployment qualification stays pending. Prior head state
(2026-07-27 — Phase `2` reclosed on proof-carrying Bootstrap Broker shutdown): Sprint `2.36`
resolves running replay completions before cancellation, keeps child
cancellation in a persistent structured tree, reports join-deadline expiry as
`BrokerShutdownIncomplete`, and publishes `BrokerStopped` only through an opaque exact-empty
postcondition witness. The deterministic finalizer-stall regression is green. Sprint `5.23` then landed its code-owned
surface — a pure, exhaustively-scheduled shutdown model (`Prodbox.Bootstrap.Broker.ShutdownModel`)
and run-final residue oracle over that witness, proving the pre-fix `Stopped + live replay waiter`
counterexample reachable and unreachable under the proof-carrying postcondition; the live
full-suite-contention exercise is the non-blocking Standard-O axis. Deployment qualification
remains pending.

> **Declarative-plan note (Standard D).** This section is a condensed milestone ledger, not a
> per-sprint changelog. The authoritative per-sprint closure detail lives in the phase documents
> ([phase-0](phase-0-planning-documentation.md) … [phase-8](phase-8-email-invite-auth.md)) and the
> cleanup history lives in [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md); the
> current status is only [Resume Here](#resume-here), while prior phase tables are retained in the
> [Historical Phase Record](#historical-phase-record) below. The dated blow-by-blow was consolidated
> here on review to keep the plan declarative.

**Historical head state (2026-07-21 — superseded on 2026-07-26 by Sprint `2.36`).** At that
revision, Phases `0`–`2` were recorded reclosed and the lifecycle-control-plane redesign continued
into Phase `3`. The
current revision is not deployment-qualified. Two full-suite attempts supplied a production
counterexample to the July 11 closure narrative:

- the nominal gateway-to-MinIO readiness request exceeded its 30-second client deadline even
  though MinIO itself was healthy;
- all three gateway replicas were pinned at their 250m CPU limits with 96–99% cgroup throttle
  periods while the continuity/heartbeat path repeatedly launched object-store subprocesses;
- a later run passed that point observation but lost the retained SES authority and release through
  the same gateway failure domain;
- the AWS selected-target precondition observed the EKS gateway while execution used the retained
  home authority;
- the fail-fast restore sequence skipped independent local chart restoration after the SES failure.

The earlier sprints remain historical completed work on their stated, narrower code-local surfaces.
They do not prove the expanded architecture. Sprint `0.16` recloses Phase `0` on the governance
and design correction. Phase `1` is reclosed on Sprint `1.67` after Sprints `1.61`–`1.66` landed
and the generic Kubernetes prerequisite was decoupled from home-local RKE2 facts. Sprint `2.32` is
Done on its code-owned single-writer emitter surface, and Phase `2` was then reclosed on Sprint `2.33`,
which extracts pre-Vault recovery into a minimal Bootstrap Broker and cuts the pre-Vault scope from
the Gateway Runtime. The 2026-07-26 shutdown counterexample supersedes only that reclosure claim.
The later numerical completion pass reclosed Phases `3`–`8` on their expanded code-owned
surfaces. Their historical closure states are recorded below and in the phase documents; live
deployment qualification remains separate under Standards O/P.

**Foundation Epoch (2026-07-12).** Governance Sprint `0.17` recloses Phase `0` a second time on
the `LCPC-2026-07-11` structural correction: cross-boundary contracts become compiled values with
generated projections, retained custody becomes durability-indexed, restoration becomes a derived
total graph, and authored capacity becomes measured-certified (and, on Sprint `1.68`, an opaque compile-time
over-commitment proof). Foundation Epoch Sprints
`1.63`–`1.66`, `2.34`, `4.51`, `5.20`, `5.21`, and `7.34` are Done. Sprints `1.61` and `1.62` are also Done after their shrink-rescoped capability and
temporal-capacity work landed (readiness evidence moved to Sprint `2.34`; the cached Vault session
and native S3 client moved to Sprints `1.64` and `1.66`). No later-phase incompleteness reopens
Phase `1` under Standard N; Sprint `1.68` later reopens Phase `1` on its **own** capacity-algebra
surface (permitted by Standard A), not on any later-phase dependency.

The target replacement is the pure-functional
[Lifecycle Control-Plane Architecture](../documents/engineering/lifecycle_control_plane_architecture.md):
a minimal Bootstrap Broker, a retained Lifecycle Authority, substrate-local Target Secret Agents,
and a mesh/DNS-only Gateway Runtime with an identity-bound emitter journal (the EKS DNS mutation
capability is disabled). Capability observation,
admission, and execution use one operation-indexed `CapabilityRef` and one absolute deadline. Lifecycle
work is a durable operation journal/outbox rather than a synchronous lease bracket, and suite
postflight is an always-run cleanup DAG.

**Deployment qualification: pending.** Standard P forbids calling the current revision seamless,
deployment-ready, fully closed, or operationally cut over until the exact revision/config digest
passes the required load, fault, consecutive aggregate, cancellation, and cleanup campaign on the
home and AWS substrate rows below.

**Preserved previous closure record.** Phase `7` reclosed after completing its own AWS bootstrap-readiness surface
([Standard A/N](development_plan_standards.md#n-phase-independence-no-backward-blocking)). Sprints
`1.56`/`3.23`/`4.43`/`7.31` landed the typed component/readiness graph, graph-sourced chart edges,
Percona `Available` gate, single step narration, and the deep registry→MinIO S3 gate on both
substrates. Sprint `4.45` now makes the home RKE2 readiness-race ordering class unrepresentable:
the validated graph determines component order, `nativeInstallStepOrder` concatenates each
component's anchored steps in that order, and edge reconciliation is an explicit separate tail.
Sprint `4.46` is ✅ Done and Phase `4` is reclosed: the Route 53, Helm, and Harbor publication retry
classifiers delegate to the shared transient-failure base, Helm now inherits the common DNS and
transport cases, and the three transitional RKE2 lint allowances are gone. Code-local evidence is
unit 1276/1276; `prodbox dev check` exits 0. Sprints
`1.57`–`1.59` are
✅ Done and Phase `1` is reclosed. Sprint `1.59`
landed the flat `ReadinessObservation` / `ReadinessProbeResult` seam, typed targets carrying
caller-injected one-shot actions, exhaustive probe dispatch, immediate mismatch refusal, and bounded
pending/unreachable waits. Its graph audit records `ProbeServiceActive` for cluster base,
daemon-mediated Vault-unseal ordering, and the gateway-full `BackendWriteEdge` to MinIO
(`config generate`/`config validate` exit 0, unit 1259/1259, `prodbox dev check` 0). It wraps no
production primitive and owns no coordinates; the Phase-3, Phase-4, Phase-5, and AWS bindings have
landed in `3.24`, `4.45`, `5.15`, and `7.32`. Sprint `2.30` is ✅ Done and Phase `2` is
reclosed:
`VaultRoleGatewayDaemon` is the one typed
authority for the supported `ChartPlatform`-generated gateway `vault.role` and the
`defaultVaultReconcilePlan` Kubernetes-auth role name (`prodbox-gateway-daemon`), whose policy set is
exactly `prodbox-gateway` plus `gateway-gateway` (unit 1260/1260, `prodbox dev check` 0). Static chart
defaults and other gateway configuration surfaces are not claimed by this SSoT. Sprint `3.24` is ✅
Done and Phase `3` is reclosed: the exhaustive `operatorAvailableTarget` registry routes the Percona
operator through a one-shot `Available=True` observation and `ReadinessObservation`; only
`ReadyObserved` opens the chart mutation gate. A new `ComponentId` constructor requires an explicit
registry decision in the warning-clean build, while an existing config-driven ID without a target
fails closed at runtime (unit 1266/1266, chart lint 0, `prodbox dev check` 0). Sprint `4.44` is ✅
Done: `RegistryStorageBackend` now carries the rendered non-secret registry S3 settings plus a required
`RedirectPolicy`; the canonical MinIO-backed value selects `RedirectDisabled`. `registryConfigYaml`
remains an `unlines` renderer but consumes that typed input. The golden output is preserved, and
resource ownership is unchanged (registry-config golden, unit 1268/1268, `prodbox dev check` 0).
Sprint `4.45` is ✅ Done: `buildNativeInstallExecutionPlan` validates the component DAG, derives
`concatMap stepsForComponent (componentReconcileOrder dag)`, verifies dependency and phase
monotonicity, and carries the validated DAG/order in its compiled `NativeInstallPayload`; any
invalid projection returns a structured error before apply. Graph declarations now include the
registry and post-Vault dependencies actually consumed by cert-manager, the pre-Vault gateway,
MetalLB, Envoy Gateway, and Percona. Every native step has a total anchor and both phase executors
match explicitly; MetalLB, Envoy Gateway, and Percona are first-class steps. Production readiness
targets invoke their caller-injected one-shot observations through bounded fail-closed polling,
with each component's final anchored barrier required before its dependants run. The plan goldens
intentionally expose those three platform steps and
remove the redundant home MinIO steady-state narration (config schema regeneration and validation
exit 0, unit 1273/1273, real `prodbox cluster reconcile --dry-run` exit 0, `prodbox dev check` 0).
Phase `4` is reclosed after Sprint `4.46`. Sprint `5.15` is ✅ Done and Phase `5` is reclosed:
`Prodbox.TestRestore` owns one substrate-aware typed restore-cycle plan consumed by both TestRunner
restore paths, and the optional SMTP step opens only after a bounded, fail-closed gateway object-store
precondition. Code-local evidence is unit 1280/1280; `prodbox dev check` exits 0. The home
`prodbox test all` restore-cycle proof remains a non-blocking Standard O axis. Sprint `7.32` is ✅
Done and Phase `7` is reclosed: the configured DAG compiles to a closed AWS anchored-step order
before mutation, every AWS-owned component has a production one-shot target, the gateway Service
port-forward spans daemon-mediated Vault bootstrap/full-mode convergence, the EKS classifier uses
the shared base with no lint allowance, and AWS bootstrap projects the shared restore builder.
Code-local evidence is unit 1286/1286 and `prodbox dev check` exit 0. The live
`prodbox test all --substrate aws` past the EKS image-mirror step is the
non-blocking Standard O live-proof axis (see [Substrate Parity](#substrate-parity) and
[substrates.md](substrates.md)).

### Milestone ledger

| 2026-08-14 | Sprints `2.48` ✅ + `2.50` ✅ **The last open sprint in the plan closes, and the entry's finding is that reading an object beat reasoning about it — against this plan's own text.** Sprint `2.50`'s registered row said the stuck secret-worker checkpoint was "Vault-enveloped and its completion state has not been decoded", and gave that as the reason the failing arm could not yet be named. **Both halves were wrong.** The bootstrap store's `StoredEnvelope` is canonical CBOR over `SecretFreeWorkerRequest` — *secret-free by construction*, which the type name says outright — inlined in the MinIO object and readable with **no Vault session**, on a host whose Vault is uninitialized. The caution had made the decode look impossible on exactly the host where it was trivial; one `xxd` settled it. **The decode then corrected a count**: two compared fields cannot repeat across invocations, said the plan — it is **three**, because the operation deadline is `acceptedAt + budget`. Same shape as the withdrawn "eleven layers" numeral and the "nine payload types" correction before it: *an inventory stated in prose is not a measurement*. **And the reason nobody caught it is the sprint's other deliverable**, which makes this the first instance of that collapse whose cost is demonstrable rather than argued: `EngineSecretWorkerStoredRequestBindingMismatch` was payload-free and produced at **five** distinct sites, so no run could ever have said which fields disagreed. Fifth instance of the shape Sprints `2.46`–`2.49` each closed one layer up. **The remedy is narrower than any of the three options registered, and the bound that scoped the sprint chose it rather than being argued across**: a checkpoint is a *result* record — but that is a statement about checkpoints which **carry** a result, and the stuck one is `InternalNoWorkerReceipt`, whose entire meaning is that none was captured. Roll arm widened, bounded three ways — pre-receipt only, a **strictly older** fence generation only (newer refuses outright; equality keeps the identical-binding rule, because one session's worker operations are ordered), and the predecessor's worker **destroyed** by a UID-preconditioned delete rather than observed absent, which is stronger than Sprint `2.47`'s absence observation because it causes absence instead of inferring it. Exactly one of the seven cases in the pre-existing exhaustive mismatch table changes behaviour; receipted checkpoints stay refused on every binding; the regression case was **run against frozen prior behaviour** rather than asserted. Sprint `2.48` ✅ closed both items it carried. The 300-second Lease coupling is **declared, not removed by renewing**, on an argument that inverts the obvious one: renewal is *adversarial* to Sprint `2.47`, because retirement takes over an abandoned fence only against a positively expired Lease, so a renewer outliving a wedged bring-up would restore the permanent wedge `2.47` closed — **the Lease expiring on its own is the mechanism, not the omission**. And the acquisition-path fence leak now compensates through an exact-value CAS back to vacant, closing that row **with its owning sprint** rather than leaving the orphan shape this plan has caught three times; **retirement could not have served**, which is worth recording because it was the obvious reach — it requires the durable operation deadline to have elapsed, and a freshly acquired fence's has not. **And the plan briefly had no open sprint, which `2.50`'s own forward proof took away within the hour.** That proof passed on the arm it changed — the durable checkpoint was rewritten from store version 2 at fence generation 7 to version 4 at generation 13, which nothing but `driveSecretWorker` writes — and the run then failed at a **fifth** defect in the same chain: the worker Pod's image pinned to the controller's `imageID`, a **config** digest on a locally-built host, where a registry can only resolve a **manifest** digest. Registered as Sprint `2.51` 🔄 with reproduction *and* cause taken, which is unusual at registration and is the dividend of `2.46`–`2.50`. **The structural half outlasts the instance**: the two digests are the same sixty-four hex characters, separable by no smart constructor over the text — [§ 24](../documents/engineering/chaos_hardening_doctrine.md) exactly. **And one probe taken while measuring it was wrong and is recorded rather than corrected silently**: a by-tag registry request with only the Docker v2 `Accept` header returned 404, reading as a lost push; adding the OCI media types returned 200. Evidence: `dev check` 0, `test unit` 0 (**3468** + 27 + 33 + 27), `test integration cli` **57/57**, `test integration env` **57/57**. Ledger: **pending 66 → 65, unowned 2 → 2, completed 299 → 301**, derived. Deployment qualification: both sprints move Standard-P persistence/lifecycle surfaces; both substrate rows stay `pending`. |
| 2026-08-14 | Sprints `2.47` ✅ + `2.48` 🔄 **The plan's oldest open defect closes, and it closes on a mechanism that was already in the tree with zero production callers.** A failed bring-up left a durable `bootstrap-session-fence` no supported command cleared; `--cascade` preserves `.data/` by design because the same tree holds per-run Pulumi state; an expired predecessor was never taken over implicitly, so the host could never complete `prodbox vault init` again. `decideBootstrapFenceRetire` was the remedy all along — three independent facts, each refusing closed on ambiguity, **stricter than all three options the ledger row proposed** — with its store half fully wired and nothing calling it. **The reason it was unwired is structural, and naming it is what made the sprint small**: the cleanup observation it consumes was bound to a seven-field `SecretWorkerCleanupBinding`, and a durable fence carries **three** of those seven, so a successor holding only a stale fence could never construct one. Closed by observing worker absence **by fence generation** — checked in both directions, so an answer about another generation is unobservable rather than absence ([§ 24](../documents/engineering/chaos_hardening_doctrine.md)) — and by wiring acquire → retire → re-acquire with the second pass bounded **structurally** rather than by a counter. **The bound is stated at the wiring site rather than left to be re-derived**: Pod absence is not Vault-session absence, and it need not be, because every Vault effect re-reads the exact fence immediately before acting, so retiring the fence *is* the revocation. **Seven prescribed remedies were refuted by measurement across the row's life** — option 2 inert (`G == G`, both objects observed on the operator host), the "design decision" framing, the annotation-*selector* claim, an unreachable new constructor **deleted rather than shipped**, a replacement mechanism that was unnecessary **and would have been worse** (its label also matches the Broker's own controller Pod), "every construction site including the fakes" reduced by one grep to one field and no fakes, and a never-renewed Lease that looked like a 300-second ceiling and is not — because `maximumBrokerRequestDeadlineMilliseconds` is the same 300 seconds, an **undeclared coupling** handed to `2.48` rather than absorbed. `2.48` 🔄 owns the second, distinct Lease blocker, its reproduction already taken; **its first defect was the record itself** — the ledger held the paraphrase "no Lease present" where six constructors were available, because `ensureLease` narrated one fixed string for all six, the exact collapse Sprint `2.46` fixed one level up and this function was missed by. `2.47` closed that narration, so the next reproduction names the arm. **Two Standard-C corrections landed with it, both of the same family**: Sprint `4.82`'s recorded `dev check` exit 0 did not reproduce (a Sprint-`4.76` record literal left incomplete by `4.82`'s new field — `-Wmissing-fields`, which only `dev check`'s `-Werror` promotes, so `test unit` passed anyway), and Phase `2`'s header still led with the 2026-08-10 reopen while every sprint in it read ✅ — the precise failure that header was corrected for on 2026-08-08. Evidence: `dev check` 0, `test unit` 0 (**3453** + 27 + 33 + 27), `test integration cli` **57/57**. Ledger: **pending 65 → 65, unowned 2 → 2, completed 295 → 296**, derived. Deployment qualification: `2.47` moves a Standard-P persistence/lifecycle surface; both substrate rows stay `pending`, and both sprints' live proofs stay 🧪 Standard-O. |
| 2026-08-14 | Sprints `4.81` ✅ + `4.82` ✅ + `2.47` 🔄 **Done; Phase `4` reopens and recloses the same day on a doctrine gap rather than a failure, and a sprint the plan had been citing is finally written.** [chaos_hardening_doctrine.md § 24](../documents/engineering/chaos_hardening_doctrine.md) requires a derived value to be enforced at the layer its source object is authoritative for, and to name that layer; `ResidueStatus` is the common target of **nineteen** producers — Pulumi checkpoint store, AWS resource presence, AWS IAM, AWS EBS, config text, Pulsar topic, Vault gate, object listing, SES consumer quiescence, public-edge TLS, plus an aggregate fold and a transport-failure constructor that are not observations at all — and has no field in which to name one. The layers are **enumerated rather than counted**: nineteen is a signature grep, a layer numeral would be a bucketing judgement. **The defining module states the rule and erases it ten lines later**: `PresenceObservation` and `CheckpointObservation` are documented there as "deliberately independent … separate external facts", and two production conversions join them into the same flat type. [Standard L](development_plan_standards.md#l-cli-doctrine-alignment) makes scheduling a doctrine gap mandatory, which is why this is a reopen rather than a note. **The consequence was already in this document's prose, unowned, since 2026-08-11** — the per-run residue query observes the Authority and its answer is consumed as an AWS-resource fact — and Sprint `4.76`'s Remaining Work had said "none on the code-owned surface"; **registering an observation as prose is not registering it as work.** `4.81` makes the layer sayable and its minting restricted, as a **field with a class-A opaque minter and a `dev check` boundary, not a type index** — § 21 names *residue* explicitly in its prohibition on indexing an observed value, so the remedy was constrained before the sprint began — and it retires `ResidueBackendMinioUnreachable` as the label for authentication failures against a service never contacted. `4.82` makes the cascade consume the layer it needs, using the admin credential `runCascadePostflightTagSweep` already loads in the same run; its acceptance criterion is the **inverse of Sprint `4.76`'s live run** — identical host state, exit 0, narration naming AWS — plus a second run proving the refusal arm still refuses. `2.47` owns the bootstrap-fence row: **it existed in citations before it existed as a sprint**, and its prediction that "the next failed run will re-poison the host identically" was confirmed by a fence object dated `2026-08-13 23:06` surviving a `--cascade` on the operator host. No § 25 is added and no § 12 row: § 24 already prescribes the behaviour, and inventing a coordinate for an existing rule is the "n+1-th opaque wrapper" move § 23 warns against. Evidence: `dev check` 0, `test unit` 0 (**3444** + 27 + 33 + 27 — reconciling exactly with the measured 3430 baseline plus 6 plus 8), `test integration cli` **57/57**; `checkResidueObservationMinter` mutation-proven and the file restored byte-exactly. Ledger across the day: **pending 65 → 68 → 65, unowned 3 → 2, completed 292 → 295**, with the previous entry's figures corrected under Standard C because they were restated in the entry immediately after the one that published the derivation to prevent that. Deployment qualification: **both sprints move Standard-P destructive-cleanup surfaces**; both substrate rows stay `pending`, and `4.82`'s inverse-of-`4.76` live proof stays 🧪 Standard-O pending. |
| 2026-08-11 | Sprint `3.34` ✅ + Sprint `2.43` 🔄 **Done; Phase `3` recloses, and fixing the cause exposes what it masked.** The Kubernetes API egress coordinate now has the compiled owner it lacked: `KubernetesApiEgressCoordinate`, observed once from `endpoints/kubernetes`, which yields the post-DNAT address **and** port together. The previous observation read `service/kubernetes` — the pre-DNAT coordinate — which is why deriving from a single source had fixed the encoder count and not the layer; that is the § 24 rule this implements. `apiEgress` renders one `ipBlock` per observed address plus the observed port, and the two charts carrying the coordinate bind `.Values.kubernetesApiEgress.*` instead of restating a literal. Three coordinates are now distinct and stay distinct: the policy-matched endpoint pair; `kubernetes.default.svc.cluster.local:443` in `K8s/InCluster.hs` and `Vault/Reconcile.hs`, which is what a **client dials** and is correct pre-DNAT; and the nine `ipBlock: 0.0.0.0/0` public-HTTPS literals, which this owner does not speak for. The sibling lint `chartTemplatePortLiteralViolations` widens the chart-lint region to **every** repo-owned chart template under the closed key set `port:`/`targetPort:`/`containerPort:`/`nodePort:`/`hostPort:`, so a `networkpolicy.yaml` is read for content for the first time; named ports and `{{ .Values… }}` are not all-digit and fall out of the predicate, so the region carries no allowlist. **The first run named 77 findings**, which reconciles exactly with the 79 measured on 2026-08-10 less the two the owner had already migrated — reported rather than rounded, because a gate whose first run finds nothing has had its region drawn to fit the code. Evidence: `prodbox dev check` exit 0; `prodbox test unit` exit 0 (3325 + 27 + 33 + 27); the two-region mutation reintroduced `port: 443` and the new region exited 1 naming file and line 59 while the old region stayed at 0, restored byte-exactly by md5; both deletion anchors were exercised by mutation and each failed as required. **The honest bound holds**: the lint closes drift between a rendered value and its compiled owner, not correctness of the owner — with the owner still saying `443` the cluster would break identically, only a live run proves `6443`, and the gate is not credited with catching the outage. Deployment qualification: this **does** edit a live production rendering path, so the next qualification run must exercise the post-`3.34` rendering; both substrate rows stay `pending`. **Sprint `2.43` 🔄 Active** registers what the fix uncovered: with API calls succeeding for the first time, three further defects appeared on the broker readiness path, each masked by the one before — a self-observation selector missing the repo-wide `prodbox-` prefix (the only unprefixed occurrence in the repository), a `PodWire` decoder requiring the `apiVersion`/`kind` that Kubernetes omits on `PodList` items, and a controller-image check requiring a `:latest` tag the harness overrides on both substrates. None could have been seen before `3.34` landed. They are registered rather than patched silently (Standard L), and Sprint `3.34`'s validation 5 stays 🧪 Standard-O pending on them. |
| 2026-08-11 | Sprint `2.42` ✅ **Done; Phase `2` recloses on its own-surface reopen.** The broker's readiness reason now survives its transport. Six sites in `productionKubernetesWorkerBoundary` matched `Left _` and substituted a constant — the two `BootstrapLeaseUnobservable` sites and the four `SecretWorker*Unobservable` sites — and fixing them alone would have been insufficient, because `requestKubernetes` had already collapsed its caught `HttpException` to a bare `"Kubernetes API request failed"`: the reason would have gained a prefix and no information. The exception is now classified at the helper by `kubernetesTransportFailureLabel`, which matches every `HttpExceptionContent` constructor of `http-client` 0.7.19 plus `InvalidUrlException` onto fixed labels. **`show` is the wrong implementation here and the sprint said so in advance**: `show` on `HttpExceptionRequest` prints the `Request`, and every request this boundary issues carries an `Authorization: Bearer` header, so rendering the exception would have turned an operator-visible readiness body into a credential-disclosure surface. The `Request` is matched as `_`, no constructor argument is interpolated — `InvalidRequestHeader` can carry the `Authorization` header itself and the two proxy constructors can carry proxy credentials — and the match has no wildcard arm, so a new upstream constructor is a compile error rather than a silent collapse. Evidence: 25 cases in `test/unit/BootstrapBrokerProductionBoundary.hs` — 21 constructor fixtures asserted by exact string, mutual distinctness, non-emptiness, a negative case proving the bare site phrase is unreachable, and a credential-safety case planting a bearer token in the four credential-carrying constructors and asserting that neither it nor `Authorization` nor `Bearer` reaches a rendered reason; `prodbox dev check` exit 0; `prodbox test unit` exit 0 (3319 + 27 + 33 + 27). **The honest bound**: this shortens the distance between a transport failure and its diagnosis, it does not prevent one. The outage that registered it is Sprint `3.34`'s to fix and remains open; `2.42` is not credited with addressing the cause. Deployment qualification: unchanged — the change is to a reason string, not to the readiness verdict, the probe wiring, or any rendered manifest, so no Standard-P surface moves and both substrate rows stay `pending`. |
| 2026-08-10 | Sprint `0.26` ✅ + Sprints `3.34` 📋 / `2.42` 📋 **An observation has a layer; Phases `2` and `3` reopen on their own surfaces (Standard A/N).** A live AWS-substrate run failed at the `bootstrap-broker` Helm release eight consecutive times: the chart permits Kubernetes API egress on TCP `443`, kube-proxy DNATs the Service to its endpoint on `6443` before the CNI evaluates egress, and the rule matches nothing — `/healthz` 200, `/readyz` 503, `helm upgrade --wait` expired at thirty minutes. The coordinate has **no compiled owner** (`grep -rn "6443" src/` returns one hit, a kubeconfig string-match), so three sites each author their own and the DNAT fact exists in the repository only as a chart comment. `apiEgress` is the instructive case: it *is* generated from a live observation and is wrong in **both** coordinates, because it observes the Service (pre-DNAT) while policy is evaluated post-DNAT — deriving from one source fixes the encoder count, not the layer. `0.26` appends `chaos_hardening_doctrine.md` § 24 plus a § 12 ledger row, and corrects in place the probe/route single-source claim, which read as a property of every chart while the lint covers seven charts on hand-listed filenames and **no gate reads a `networkpolicy.yaml` for content at all** (79 numeric port literals across 13 charts un-gated). `3.34` gives the coordinate one owner derived from `endpoints/kubernetes`; `2.42` stops the broker discarding the typed transport failure that made the outage cost eight runs to find. Evidence: control test — unpolicied pods reach `https://10.43.0.1:443/healthz` and are answered `401`, the policied pod times out at curl exit 28; `prodbox dev check` exit 0 over the governed-document harmony set. The lint `3.34` adds closes drift, not correctness, and is **not** credited with catching this outage. **Deployment qualification: pending** — unchanged; `3.34` will edit rendered NetworkPolicy egress, which is capability wiring, so the next qualification run must exercise the post-`3.34` rendering. |
| 2026-08-09 | Sprint `5.31` ✅ **Done; Phase 5 reclosed and every code-owned phase is closed.** The final four installed-integration failures were corrected against source: the fake cluster exposed three gateway Pods against an exact typed projection of two; a transient primary code-server image push retries and succeeds without selecting the fallback; config setup emits the derived Dhall union constructor and is asserted through structural decode rather than the retired bare-string shape; and the AWS-IAM teardown fixture now supplies a valid fixture subzone so it reaches its already-specified unavailable-Credential-Provisioner refusal. Evidence: installed `cli` and `env` integration suites **55/55**; canonical `prodbox test unit` exit 0 with main Hspec **3255/3255**. Clean-room deployment qualification remains `pending` under Standards O/P. |
| 2026-08-08 | Sprints `5.31` 🔄 + `4.61` ✅ **A discarded refusal, and the production defect it was hiding.** `runAnchoredStepOrder` ended in `refuse _ = ExitFailure 1` — the typed `AdmissionRefusal` thrown away with a wildcard on a path that emitted nothing, so eight integration cases exited 1 with no stdout line and no stderr line. `renderAdmissionRefusal` already existed and was already exported; the crossing did not use it. § 23 at the step boundary. The fix returns `Either AdmissionRefusal (ExitCode, AdmissionSet)` so there is no `ExitCode` to return in a refusal's place — unrepresentable, not merely absent — and both callers render it where a reason belongs. **One run later it named a production defect**: admissions were reset at every phase boundary, so `chart_authority_backup` was refused for a `registry` admission that the same run had recorded one phase earlier. `4.61` threads the set through bootstrap → transition → steady (and across the AWS port-forward split), with staleness untouched — an aged admission still expires and re-observes. Three further fixture drifts sat underneath, ending in the capacity drift Phase 5 had registered as silent: the fake LimitRange declared the gateway at 250m where the plan projects 750m. The fixture's observed cluster state now *renders from* `namespaceResourceQuotaHardFields` / `namespaceLimitRangeContainerFields`, the same projection the validator compares against, so a fake can no longer restate a production number and drift from it. Integration **20 of 55 → 4**. Evidence: `dev check` exit 0, unit 3253/3253, `dev docs check` and `dev lint docs` exit 0. |
| 2026-08-08 | Sprint `5.30` ✅ **One Tier-0 encoder, and a gate region that covers the evidence.** The test tree carried four hand-written encoders of a record with exactly one decoder; `test/support/Tier0Fixture.hs` is now the only module that produces Tier-0 document text, every valid fixture is a typed value rendered through the canonical `renderProjectConfigDhall`, and `wrapTier0`/`wrapTier0WithComponents`/`wrapTier0WithDefaultComponentGraph`/`writeRootBasics` plus ~33 Dhall fragment helpers are deleted (`EnvSuite.hs` alone: −282/+70). The escape hatch is closed and *checked* — `ExercisesGeneratedSchemaImport` verifies the import actually happens, `MustNotTypeCheckAgainst` verifies the violated field is named, and there is deliberately no "not yet migrated" arm because that state is the defect. Even the raw escape derives its envelope, through the newly exported `renderProdboxContextDhall`, so the test tree gained no encoder of its own. `--enable-tests` joins the canonical build in `CheckCode.hs` and `TestRunner.hs`; **turning it on immediately produced 33 `-Werror` findings in `test/` the old region had never seen.** The two-region mutation is the evidence: a field added to `DeploymentSection` with every production site updated builds **exit 0** under `cabal build all` and **exit 1** under `all --enable-tests`, naming `test/unit/Main.hs:17103`. Integration 20 of 55 failing → **8**; the remaining 8 are one non-fixture defect, registered as `5.31` rather than absorbed. Evidence: `dev check` exit 0 with `--enable-tests` in force, unit 3253/3253 including the new 9/9 fixture suite. |
| 2026-08-08 | Sprint `4.60` ✅ **A server answers an accepted connection, or the attempt to answer fails loudly.** `Prodbox.Http.ResponseObligation` is the only module in the governed set permitted to import `Network.Socket.ByteString`; the control-plane server and the integration fixture server both route through it, and a `dev check` rule refuses a governed server that brings a raw socket write back into scope. Two design points are load-bearing rather than stylistic: the handler returns `reply` and not `()`, so a handler that computes no reply does not type-check; and the fallback is a *total function of a closed refusal* rather than a constant, because production must not put an exception's text on the wire while a fixture server must — a constant would have forced the fixture to fork the helper, which is the topology that produced the defect. `SomeAsyncException` is answered best-effort and re-raised unchanged, since `System.Timeout.Timeout` is asynchronous and converting it to a `500` would silently defeat every enclosing deadline. Evidence: `dev check` exit 0, unit 3245/3245 including 9/9 obligation cases and 3 new end-to-end control-plane cases. |
| 2026-08-08 | Sprint `0.25` ✅ **MISU is corrected where it actually failed: at conversions, and over a region.** Twenty integration cases were failing because Sprint `1.80`'s closed-union tightening — a textbook § 21 class-D move on the field § 21 itself names — invalidated three of the four hand-written Tier-0 encoders in the test tree, and the resulting decode failure was converted into an `ioError`, then into a socket closed with zero bytes, then into `NoResponseDataReceived`. Five minting-boundary gates were in force and none fired: each constrains a value *inside* `src/`, and all three conversions were out of it. `chaos_hardening_doctrine.md` gains **§ 23** (one derived encoder per crossing; do not convert a typed failure into an untyped one; remove the conversion before adding a proof — adding an n+1-th opaque wrapper to a repository whose n wrappers did not fire is answering the wrong question), a fourth honest consequence in § 22, a § 12 ledger row, and an in-place correction of § 21's "Neither needs new doctrine". `resource_scaling_doctrine.md` § 2C — which § 22 delegates the ring vocabulary to — gains **"The region of Ring 2"**, with the measurement: `cabal build … all --dry-run` lists two components, `--enable-tests` lists ten. Seven dependent docs and the root `README.md` inherit the qualifier by reference rather than restatement. **The section-citation gate caught an authoring error mid-sprint** — a `§ 0.5` placed after a link bound to the wrong document — which is the `0.22` gate doing exactly its job. No section renumbered, so ~40 bound `§ 21`/`§ 22` citations across docs, plan and `src/` Haddock are untouched. Sprints `5.30` and `4.60` registered 📋 for the code. Evidence: `dev docs check`, `dev lint docs`, `dev check` all exit 0. |
| 2026-08-07 | Sprint `0.23` ✅ **The Tier-0 config doctrine is corrected against source; three governed-document claims were false.** An audit asked whether the design makes illegal state unrepresentable in the Dhall config. For *categorical* state it largely does — closed unions wherever the legal set is a fixed vocabulary — substrate, component identity, dependency-edge kind, readiness-probe kind, QoS class, scaling policy, and secret-reference shape all refuse a misspelling at Dhall type-check. For *value-level* state it does not, which is expected and already doctrine: Dhall has no refinement types and § 2C names Ring 2, not Ring 1, as the ring that delivers. What was **not** expected: § 2C defended Ring 1 with "`prodbox.dhall` is binary-generated (no human Dhall authoring surface)", contradicting its own next sentence — the file is hand-editable, `CLAUDE.md` lists editing it as the *automation* path, three sections have no generator path, and nothing detects drift; `config_doctrine.md` claimed "zero version-controlled `.dhall`" where `git ls-files` returns five; and `code_quality.md` listed `prodbox-config-types.dhall` as a tracked generated path with a gate, where it is git-ignored and absent from `CheckCode.hs` entirely. All three corrected in place per Standard C, plus an honest "what decoding does and does not validate" subsection: the Ring-2 gate is a flat list of checks over a twelve-field record rather than a total function, and `ValidatedSettings` carries the raw record with the capacity plan as its one required proof. **No prior sprint closure was falsified** — each candidate was checked against its cited evidence and every claim held within its stated scope, so no phase reopens on this account. Sprints `1.79`–`1.81` and `0.24` are registered 📋 Planned for the code. Evidence: `dev check`, `dev docs check`, `dev lint docs` all exit 0, which is also the mechanical proof the new text passes the `0.21` cited-path and `0.22` section-citation gates. |
| 2026-08-06 | Sprint `4.58` ✅ **The one target-sink token Vault itself checks stops being authorable, and this plan's own account of the defect is corrected for the second time.** Increment B was recorded as "a second writer routes around the permit", to be fixed by making `TargetSinkCasRequest` opaque. Source re-verification refuted that on four counts: the writer is fenced — by an Ed25519-signed, fence-floor-checked `VerifiedTargetCommittedIntent` rather than by the `FencedCommitPermit` the row grepped for; it has zero production callers and its unit suite is compiled but never registered; the prescribed fix does not compile, because the module cannot mint the permit it would require; and the class was Provenance, not Cardinality, since Vault KV v2 inspects only `options.cas`. What was genuinely closable is the expected version itself, which `mkTargetSinkVersion` accepted from any string literal while its one legitimate minter round-tripped the store's counter through `Text.pack . show`. `TargetSinkVersion` now lives in its own module, abstract to every consumer, with its constructor confined to an internal module having exactly one permitted importer — the Vault observation decoder — so an expected version is evidence a store read happened. The retype from `Text` to the store's `Natural` also deletes a parse and its refusal path from the write path and corrects `Ord` from lexicographic to numeric. Sprint `4.59` is registered to delete the superseded lane. Evidence: focused 8/8 plus five moved-fixture suites (87/87, 13/13, 5/5, 4/4, 2/2), two byte-exactly-restored mutation exercises — authoring a version outside the internal module is `GHC-01928`, and a second internal importer fails `dev check` — and `prodbox dev check` exit 0. **Sixth stated premise about this area to fail on inspection; third authored by this plan.** |
| 2026-08-05 | Sprint `0.21` ✅ **Governed-document metadata reconciliation — two header fields become machine gates, one is struck.** The `**Status**:` value set is now closed and enforced (§ 9 had named `**Status**: WIP` an anti-pattern with nothing behind it), and every backtick-quoted `src/…​.hs` / `test/…​.hs` citation in `DEVELOPMENT_PLAN/` must resolve in the worktree or be a declared historical retirement — the mechanical form of the evidence sweep that keeps finding real defects by hand. Its first run flagged nine stale citations, including Sprint `4.51`'s two dead Increment-B evidence citations, all repaired. `retiredCitedSourcePaths` derives from the existing removed-legacy-transport lint list rather than re-authoring it. The `**Referenced by**:` field is struck repository-wide (480 lines across 62 documents): generation was implemented and measured first and produced 2,421 characters of header on this file, while the authored field measured 53 stale / 660 missing entries with nothing a search could not reconstruct. The reverse edge is now recovered by `grep`, at the section granularity the field never expressed. Governance addition on the already-reclosed Phase 0 surface — no reclose event. Evidence: focused 16/16, `prodbox dev lint docs` / `dev docs check` / `dev check` exit 0. |
| 2026-08-01 | Sprint `4.50` 🔄 **Active — retained SMTP/EAB Authority delivery and both supported callers are production-bound.** Lifecycle Authority now owns schema-specific retained source catalogs plus per-target `CrossClusterDurable` outboxes, persists intent before effect, re-observes exact Target metadata after response loss, and invokes only the registered Target Agent's schema-closed rewrap plus attested one-shot materializer. The Authority Pod receives a dedicated projected controller JWT with matching bounded Vault role and namespaced worker RBAC. Home EAB reconcile and the SES SMTP AWS-admin worker both call the authenticated route with exact source HMAC/ciphertext evidence; the corrected EAB receipt keeps those values distinct. Evidence: retained aggregate 11/11, external-material 13/13, Credential Provisioner 41/41, authentication 33/33, authenticated transport 27/27, warning-clean 468-module build, and `prodbox dev check` exit 0 with zero HLint hints. TLS, Provider, legacy deletion, and aggregate qualification keep the sprint Active. |
| 2026-08-01 | Sprint `4.50` 🔄 **Active — retained delivery durable-state and recovery foundation is validated.** The two closed schemas now use canonical Model-B aggregate codecs and exact-revision repositories with persist-before-effect begin/receipt commits. Recovery observes the selected Target before retry, never replays a persisted intent with a different ephemeral opening key, waits through the absolute deadline, and expires a receipt-less pending intent only strictly afterward. Evidence: focused aggregate/repository suite 10/10, warning-clean 466-module executable build, and `prodbox dev check` exit 0 with zero HLint hints. The authenticated Authority endpoint and supported caller remain open, so this is not a sprint closure checkpoint. |
| 2026-08-01 | Sprint `4.50` 🔄 **Active — retained SMTP/EAB rewrap mechanics are production-composed.** The retained-home Target Agent binds only the two schema-indexed Vault custody lanes; it validates the exact source receipt/generation/version/ciphertext digest and destination key before returning a ciphertext envelope plus Agent-HMAC receipt. The selected-target composition creates an ephemeral X25519 pair, verifies the returned envelope digest, sends the private opening only through the already-attested one-shot worker, and materializes the closed SMTP or EAB payload under generation CAS. Expiry, target/source/key substitution, absent/corrupt/unobservable custody, and newer-generation drift fail closed. Evidence: `prodbox dev check` exit 0 with zero HLint hints and a warning-clean 464-module build. The durable Lifecycle Authority delivery-outbox/caller remains open, so this is not a sprint closure checkpoint. |
| 2026-08-01 | Sprint `4.50` 🔄 **Active — direct selected-Target AWS delivery and exact receipt recovery are production-bound.** The default verified AWS-admin worker now composes the Authority intent client, metadata-only Target Agent observer, bounded auditor session, and attested one-shot Kubernetes materializer; it no longer terminates at the former missing-delivery refusal. Target metadata durably records the exact request/action/Pod-UID/image tuple, recovery reconstructs only that receipt, older generations retry, and an unexpectedly newer generation refuses. Network policy admits only the secret-free Target observation edge; plaintext still enters solely through Pod attach. Evidence: warning-clean 463-module executable build and the complete unit gate (2,965 main + 27 retained-admission + 33 authentication + 27 authenticated-transport). Selected-target retained SMTP/EAB delivery and remaining deletion work keep the sprint Active. |

Each row is one dated reopen/closure milestone; the owning phase doc carries the per-sprint detail.

| Date | Milestone |
|------|-----------|
| 2026-08-03 | Sprint `0.20` ✅ **Done; repository value hygiene adopted** — `vault_doctrine.md` §20 is retitled from *secret* to *value* hygiene and restated around one rule: every committed non-secret value standing in for real-world data is officially synthetic (a reserved or vendor-published placeholder), unmistakably synthetic (an `EXAMPLE` token, counting run, repeated nibble, or descriptive slug), or genuinely real and declared as such in place — the third of these already exemplified by `burn_recipient_provenance.md`. Realness dominates form, so a real value cannot pass by looking synthetic. **Why it generalizes Sprint `0.19`:** an audit found the credential class was the *cleanest* in the tree — 119 fixture literals, none realistic enough to mistake for real — while a **real Route 53 hosted-zone id had been committed across seven commits** in the version-controlled long-lived stack settings file, indistinguishable from the synthetic zone ids beside it. No credential rule would have caught it. §20 also sheds the ~30% of its text that restated §3, §4, §13, §17, and `.gitignore` — all of which live in the same document — replacing them with links. The bootstrap-floor credential registration folds back into §6.1 where it already lived, gaining the **integrity** blast radius §6.1's confidentiality-only argument missed; §17's ownership statement is reconciled; and the scanner pattern is demoted to an explicitly mechanical ring, assessed by a scanner rather than by a reader. The prior "construct the fixture value" convention is withdrawn: nothing validates fixture shape, so imitation was decoration. Exit Definition item 17 is scoped to runtime surfaces so it no longer contradicts the doctrine. Companion own-surface reopens, each landing the remediation on the phase that owns it: Sprints `1.74` (Phase 1), `3.30` (Phase 3), `5.26` (Phase 5), `7.35` (Phase 7). Twelve committed-value defects remediated; unit 3066/3066 (the full suite less the fd-flaky real-`ssh` case, excluded on this host), `dev check` exit 0. |
| 2026-08-03 | Sprint `0.19` ✅ **Done; repository secret-hygiene doctrine adopted (governance surface plus dead-credential removal)** — a push-protection rejection on a wholly fabricated credential fixture exposed that no document governed credential-shaped literals in tracked source. `vault_doctrine.md` § 20 becomes the SSoT: no secret material in tracked content; `SecretRef` discipline extended from Tier-0 Dhall to Haskell constants and chart values; a bootstrap-floor exception class with four obligations and one registered entry; and a construct-don't-spell fixture convention that deliberately preserves four load-bearing categories — published provider test vectors, cross-site correspondence fixtures, prefix-discriminator inputs, and the bare-prefix leak canaries a broader rule would have silently vacated. § 19 is scope-fixed to generated artifacts and runtime observation surfaces. `code_quality.md` records the gate beside the operator-vocabulary regex scan (content-shaped, so not in `forbiddenPathRegistry`); `unit_testing_policy.md` § 3/§ 4 carry the author-facing convention. § 20 also owns the `.gitignore` ↔ `.dockerignore` pairing rule and the ordered incident procedure. The mandated remediation landed with it: the vestigial hardcoded registry admin credential is deleted (the rendered registry config has no `auth` stanza, so it authenticated to nothing) and its two manifest assertions are inverted into leak canaries; the MinIO bootstrap credential is registered with a corrected analysis (`ClusterIP` reached via port-forward, not a localhost-only NodePort; registry-blob write access in the blast radius) and the vacuous Harbor precedent is withdrawn. Evidence: unit 3066/3066 (full suite less the fd-flaky real-`ssh` case), `dev check` exit 0. The invariant holds over the tree with zero exemptions. The three anticipated `dev check` policies and the MinIO per-install-generation migration are registered, not closed. |
| 2026-08-02 | Sprint `8.12` ✅ **Done; Phase 8 reclosed and the numerical code-owned completion pass finished** — `Prodbox.Test.Qualification.Invite` supplies one non-partial two-substrate artifact with eight assertions, 23 exhaustively classified faults, exact Authority epoch/backup restore, `RunnerLost` takeover, retained SES/EAB/TLS generations, and explicit refusal of prompt, rotation, generic export, or Authority plaintext paths. `Qualification.Evidence` embeds it and the installed counterexample remains `QualificationPendingLiveEvidence`. Evidence: invite 8/8, daemon lifecycle 27/27, unit 3067/3067, installed CLI/environment 55/55 twice, and `dev check` exit 0. Live home/AWS qualification remains pending under Standards O/P. |
| 2026-08-02 | Sprint `8.11` ✅ **Done** — the revisioned SES aggregate, Model-B repository/coordinator, exclusive legacy-frozen-provisioner writer migration, exact primary/backup checkpoint GC, generation-blocking durable target delivery, and disjoint convergent effect interpreters are code-locally complete. The Pulumi program is provider-only and legacy SMTP URNs remain typed migration evidence. Evidence: workflow 19/19, SES decommission 10/10, full unit 3059/3059, installed integration 55/55 twice, warning-clean build, and `dev check` exit 0. Sprint `8.12` is activated. |
| 2026-08-02 | Sprint `7.33` ✅ **Done; Phase 7 reclosed on its corrected scope** — AWS roles use distinct Bootstrap-Broker, Gateway-diagnostics, AWS-Target-Agent, retained-home-Authority, and Provider-Worker transports/capabilities. Target-local DNS01, exact public-A Provider intents, deterministic EKS IAM names, the pure controller-transition algebra, and nine fault dispositions are code-locally complete. **Standard-C correction:** production inert-owner/UID/child-ARN registration and the provider-family cleanup backstop were not wired by this sprint; Sprint `7.36` owns those obligations. Evidence: AWS isolation 11/11, Provider execution 18/18, full unit 3040/3040, installed integration 55/55 twice, warning-clean build, and `dev check` exit 0. Live AWS qualification remains Standard O/P; Sprint `8.11` is activated. |
| 2026-08-01 | Sprint `4.50` 🔄 **Active — retained first-reconcile continuation and Lifecycle-provider role substrate are production-bound.** Lifecycle Authority exposes only the authenticated next registered class/member digest/index/original deadline; `cluster reconcile` drives one attested AWS-admin Job at a time and re-observes until the retained journal is complete. Native IAM now converges the exact account-bound Lifecycle-provider role ARN, trust principal, provider policy, assuming identity/policy, and teardown read-back before key minting. Evidence: Credential Provisioner 27/27, native AWS clients 56/56, focused Authority 13/13, Authority Backup/continuation 15/15, and `prodbox dev check` exit 0 with zero HLint hints and a warning-clean 461-module build. Retained external-material custody and the remaining caller/deletion work keep the sprint Active. |
| 2026-08-01 | Sprint `4.50` 🔄 **Active — ACME EAB producer callers are production-bound.** The fail-closed fixture placeholder is removed: edge reconcile and cluster-bootstrapping harness suites send only the canonical bounded stdin frame through caller-specific authenticated Authority transport and the attested Job workflow. A secret-free current-ingress projection selects install, exact retained-deadline replay, or next-generation rotation; the fixture operation identity contains no secret-derived hash. Evidence: workflow/replay/cleanup 12/12, fixture frame 3/3, and `prodbox dev check` exit 0 with zero HLint hints and a warning-clean 461-module build. SES-SMTP custody and both selected-target rewrap deliveries remain code-owned, so this is not a closure checkpoint. |
| 2026-08-01 | Sprint `4.50` 🔄 **Active — SES-SMTP retained-custody producer overlay is locally validated.** The verified AWS-admin worker derives the complete canonical SMTP payload from its registered identity, seals/recovers it only through the retained-home SMTP lane, and records an actual Pod/image/request/custody-version receipt. Its Vault role gains exact SMTP source read/CAS and retained encrypt/HMAC only—no decrypt, EAB, final-target, or generic KV. Evidence: Credential Provisioner 28/28 and `prodbox dev check` exit 0 with zero HLint hints and a warning-clean 462-module build. Production direct-target fallback, overlay integration fixtures, and selected-target SMTP/EAB rewrap remain open. |
| 2026-08-01 | Sprint `4.50` 🔄 **Active — Authority-backup genesis/repair composition locally validated.** The retained admission state preserves the exact Target-generation and Adapter-backup receipts across every open epoch and temporary freeze; deterministic repair permits bind both predecessors and rotate both atomically. The production reconciler composes the purpose-bound Authority export, aggregate-only Backup Adapter, native AWS-admin coordinator/Job boundary, and exact Target receipt, and `cluster reconcile` invokes it before ordinary lifecycle work without loading administrator material on an already-healthy epoch. Evidence: main unit executable 2,956/2,956; retained-admission 27/27; authenticated transport 27/27; `prodbox dev check` exit 0 with pinned formatting, zero HLint hints, and warning-clean 461-module build. The live command was attempted but stopped before mutation because the required binary-sibling `.build/prodbox.dhall` is absent and no operator copy exists on the host; this is pending Standard-O/P evidence and is not replaced with the unit fixture. The remaining explicit 4.50 composition and deletion work stays open. |
| 2026-08-01 | Sprint `4.50` 🔄 **Active — repository doctrine and complete unit gate restored.** The full Haskell tree is canonical under the pinned Fourmolu/HLint toolchain; nested `case` control flow was extracted into named helpers, subprocess creation and terminal diagnostics route through their owning boundaries, opaque Bootstrap secret bytes are eliminated only through `PgpBoundary`, the credential-provisioner chart carries the required chart-root label, and the retained-admission fixture uses the current four-field authority coordinate. Evidence: warning-clean 456-module library/executable build; `prodbox dev check` exit 0; `prodbox test unit` exit 0 with 2,948 aggregate + 27 retained-admission + 33 authentication + 27 authenticated-transport tests. This validates a coherent 4.50 cleanup increment but does not close the sprint: executable end-to-end role/caller composition and the remaining legacy transport deletions named in Current head state remain code-owned. |
| 2026-07-31 | Sprint `4.50` 🔄 **Active — Credential Provisioner native IAM/S3 boundary landed.** The seven closed operator-material classes now map to exact native IAM/S3 programs with deterministic registry-derived identities and policies, no ambient profile/environment auth, finite access-key observation, response-loss classification, and delete/stable-absence/remint support. Authority-backup bootstrap alone may create/harden the shared retained bucket; TLS retention only adopts an exact hardened bucket and refuses absence or coordinate drift. The warning-clean library and focused fake-sender fixtures are in place. Signed permit transport, the attested AWS Job runtime/coordinator, direct Target-Agent handoff, and genesis/repair caller wiring remain code-owned, so Sprint `4.50` stays Active. |
| 2026-07-31 | Sprint `4.50` 🔄 **Active — production decommission composition validated.** `prodbox nuke` now freezes retained Authority admission, signs/commits one complete manifest, exports and preflights a byte-pinned external runner, requires the durable external-receipt acknowledgement, permanently stops against that exact binding, and executes the typed observe-before-retry graph through exact SES-provider/SMTP-IAM/Target-custody/TLS/backup/bucket interpreters. Resumption reuses the committed plan rather than rediscovering tombstoned inventory; normal Target observe/commit remains unbound. Evidence: decommission 130/130, routes 66/66, request authentication 33/33, authenticated transport 27/27, rendered NetworkPolicies, warning-clean builds, and negative scans. This closes only the decommission subgraph; ordinary Provider/Target/config/credential paths and legacy deletion remain open. |
| 2026-07-31 | Sprint `4.50` 🔄 **Active — Bootstrap Broker transport cutover validated; production readiness still closed.** Every supported `prodbox vault` command reaches the dedicated Broker through a TokenRequest-authenticated loopback client, secret operations use an attested bounded one-shot worker, named legacy/root-token/plaintext-init surfaces are deleted, and stale fixed-slot replay plus receipt-digest validation are closed. Evidence: Broker suite 104/104, forced warning-clean Broker compilation, and deleted-symbol scans. A follow-up source audit found the evidence registries and several physical Vault/PGP/child arms still unbound, plus missing observed session revocation, Transit-rotation journaling, and per-effect fresh fence/lease proof. The Broker therefore deliberately reports not ready while those code-owned blockers are completed; this row does not claim the production interpreter is closed. |
| 2026-07-31 | Sprint `4.50` 🔄 **Active — Gateway federation transport deletion in progress.** `RouteFederationChildren`, the child-bootstrap pattern, public client queries, daemon Vault handlers, and their bounded-operation constructors are physically removed. Built-daemon fixtures now require both former paths to return `404`; current doctrine assigns delivery/read-back to Lifecycle Authority and Target Secret Agent and retains the old endpoints only as historical provenance. `lib:prodbox` builds warning-clean, the focused compiled-route proof passes, and the deleted-symbol scan is empty. Broader gateway authority/object-store/target-secret/operator-write deletion remains open, so Sprint `4.50` does not close. |
| 2026-07-31 | Sprint `4.50` 🔄 **Active — Gateway continuity health probe cut over.** Native reconcile no longer uses a Pulumi object-store RPC as a daemon health proxy: both the full-mode gate and its compatibility-named observation classify the deep `/readyz` projection, with one bounded restart only for a definite not-ready response and transport failures kept distinct. The CLI fixture now proves readiness without serving a successful object-store read. The touched modules format cleanly, `CLI.Rke2` compiles under `-Werror`, and the retired probe-symbol scan is empty; the underlying legacy RPC routes remain open pending the final production-caller cutover. |
| 2026-07-31 | Sprint `4.50` 🔄 **Active — child-custody cutover in progress.** The child federation codec/plan no longer carries `ChildInitCustody`, `root_token`, or an init-KV path; the root-token write gate and `Vault.Seal` child-custody projection are deleted, fixtures assert the reusable-token shape is absent, and the child Transit policy is exact encrypt/decrypt only. The engineering doctrine now labels the old token-bearing path removed historical provenance. The warning-clean library and complete unit executable now build after concurrent edits converged; aggregate validation remains open on the broader supported-path cutover, so neither the ledger row nor Sprint `4.50` is closed. |
| 2026-07-31 | **Numerical completion pass started at Sprint `4.50`; closure claims corrected.** A source-level audit confirmed that the retained in-cluster authority repository/client path, production role-interpreter installation, full Target Secret Agent binding, provider-effect read-back, caller cutover and legacy deletion, clean-install authority choreography, credential/custody migration, and production decommission orchestration are code-owned gaps rather than non-blocking Standard-O evidence. The receipt runner additionally required semantic node/attempt validation and observe-before-retry recovery. Sprint `4.50` therefore remains Active and is the gate before `4.53`; no Phase-5 implementation proceeds until both Phase-4 open sprints validate. |
| 2026-07-30 | **Typed three-valued readiness doctrine adopted; Phases 4 & 5 reopened (Standard A). Sprints `5.25` + `4.53` Active.** The two "transient MinIO/gateway blips" from the live cold `test all` are one defect class — a *not-yet-ready* observation collapsed into a *definitively-fatal* bucket (the **bring-up dual**), when the repo's own three-valued readiness model would keep it distinct and retryable. Doctrine codified in [bootstrap_readiness_doctrine.md](../documents/engineering/bootstrap_readiness_doctrine.md) §0.9 (typed three-valued gate), §1 (bring-up-dual/fail-open defect), §2.4 (transient-vs-persistent unobservable split); [unit_testing_policy.md](../documents/engineering/unit_testing_policy.md) §6.2 updated. **Sprint `5.25`** (Phase 5, supersedes `5.24`): `GatewayUnobservableReason` splits into terminal-only + a new `GatewayObservationIncompleteReason`, with a non-absorbing `GatewayObservationIncomplete` observation routed like `GatewayPodPending` (`firstAbsorbingOutcome` matches only `GatewayPodUnobservable`) — a healthy not-yet-scraped Pod folds to the retried `NotStableYet`, never latched; the Sprint `5.24` `awaitGatewayRuntimeObservable` band-aid + its transient `Bool` are deleted. **Sprint `4.53`** (Phase 4): `ModelBObservation`/`ModelBCasResult` gain distinct retryable `ModelBEndpointUnready`/`ModelBCasEndpointUnready` (classified once at the `ModelBCasTransport` seam via `Service.isRetryableTransientFailure` + the aws-phrase fragments), `LeaseRefusal` a distinct `LeaseAuthorityEndpointUnready`, and the `LeaseRuntime` monitor + acquire/release CAS loops retry **only** that class within the lease readiness budget — every other refusal terminal (fencing-safe); persistence protocol untouched, happy path byte-identical (Phase 1/1b landed; Phase 2 deep-probe witness remaining Standard-O). Both build-enforced by a new `readinessObservationViolations` conformance gate in `CheckCode.hs`. Evidence: `prodbox dev check` exit 0 (warning-clean, fourmolu, HLint, conformance incl. the new gate); Sprint 5.16 suite 18/18; host-direct adapter 14/14; lease monitor retry/terminal/fencing-pin suites. Two Pending Removal rows added (the 5.24 band-aid; the shallow host-direct `waitForPort` gate). **Deployment qualification: pending** (harness/failure-classification fixes; no production-composition surface changes). |
| 2026-07-30 | **Sprint `5.24` ✅ Done — Phase `5` own-surface reopen (Standard A): the restore-time gateway stability gate waits out a fresh-Pod metrics-scrape gap.** A live home `prodbox test all` reproduced a deterministic restore-cycle failure that was **not** the heap-leak: the post-reconcile stability sample (`recordGatewayRuntimeStabilitySample`) fails closed on a freshly-(re)started but healthy gateway Pod whose working-set is not yet observable, because metrics-server (`/apis/metrics.k8s.io`) has not scraped the seconds-old Pod — `sampled_high_water_bytes=unobservable`, `restart_delta=0`, Pod at 39–78 MiB, far under the 448 MB threshold. The fix adds `awaitGatewayRuntimeObservable`: a read-only, **non-latching** scratch observe (folded into a throwaway `initialGatewayStabilityState`, never the run recorder) that polls until the runtime is observable or a bounded ~60 s budget elapses; a new pure classifier `gatewayStabilityUnreachableIsTransient` treats `GatewayPodObservationUnreachable`/`GatewayPayloadUnreachable` as transient (waited out) and `GatewaySnapshotPolicyMismatch` as fatal. The absorbing classifier is **unchanged**, so a real OOM/restart/over-threshold still fails closed immediately, and a runtime that stays unobservable past the budget still falls through and fails closed. Evidence: `prodbox dev check` exit 0 (warning-clean, fourmolu, HLint, conformance); Sprint 5.16 suite 18/18 (existing fail-closed tests unchanged + 1 new). **Live proof (Standard-O) — proven on a clean cold home `prodbox test all`:** the restore cycle drove `RestoreNodeReconcileChart RestoreChartGateway -> **succeeded**` (the exact node that failed with `StabilityUnreachable (GatewayMemoryReadingUnobservable)` in the pre-fix runs), and its success **unblocked the entire downstream restore graph** (`RestoreChartVscode/Api/Websocket` reconcile and `RestoreNodeWaitForPublicEdge` all `succeeded`, previously `BLOCKED`); the whole run recorded **zero** `StabilityUnreachable`/`RuntimeUnhealthy` observations with the gateway Pods at `0 restarts`. The only failed restore node, `RestoreNodePrepareRetainedSes`, failed on an **unrelated** transient MinIO-NodePort blip (`LeaseAuthorityUnobservable … could not connect to 127.0.0.1:39000` — the documented "transient MinIO-unreachable" class), not the gateway stability gate this sprint owns. A full green run through Phase 2 additionally depends on that transient object-store class and the genuine heap-leak holding off (cutover) — neither is this sprint's surface. **Deployment qualification: pending** (a harness-gate fix; changes no production composition surface). |
| 2026-07-30 | **Sprint `2.37` ✅ Done — Phase `2` own-surface reopen (Standard A): the emitter retained-assertion leak class is made non-constructible.** The 2026-07-29 live `LegacyModelBEmitter` OOM cycle (gateway-node-b restarting on its ~460 MiB cgroup limit) is a retained-assertion (unacked-suffix) growth class that also existed in the Sprint `2.32` cutover-target `JournalLeaseEmitter` kernel: Sprint `2.32` correction (3) declared the `emitterUnacked` bound at the durable projection boundary and claimed it enforced by a "size-triggered checkpoint fold", but the fold's compaction depends on the signer succeeding and there was no hard ceiling on the live suffix — so a stalled signer (`CheckpointFailed` left the pending candidate un-driven) grew the suffix without bound. The fix moves the bound to the **live growth point** as a hidden-constructor `BoundedUnackedSuffix` whose only growth op `appendUnacked` fails closed at the ceiling (`RejectUnackedSuffixFull`), so an over-retention state has no representation on either the live or durable side; and closes the wedge at its root — a `CheckpointFailed` outcome now re-emits the exact `EffCheckpointCompaction` so the signer retries the pending candidate. The ceiling reuses the pre-existing `projectionMaximumRetainedAssertions` durable bound; `durableProjectionUnacked :: [UnackedAssertion]` is unchanged, so retained journals round-trip byte-for-byte (no migration). Evidence: `prodbox dev check` exit 0 (warning-clean `-Werror`, fourmolu, HLint, conformance); Sprint 2.32 kernel/actor 121/121; Sprint 2.31 bounded gateway core 65/65; two new kernel fixtures (non-constructible ceiling; failed-checkpoint recompaction). This hardens the cutover **target** emitter against the leak class; the deployed `LegacyModelBEmitter` continuity path is unmodified baseline residue scheduled for deletion at cutover (Standard P), and a live ≥2.4h leak-free run remains the non-blocking Standard-O axis. **Deployment qualification: pending** (advances, does not close, the Standard-P leak-free requirement). |
| 2026-07-29 | **LIVE PROOF (Standard-O, home-local, current `LegacyModelBEmitter` baseline) — full home substrate stood up and served end-to-end on the Bathurst host.** `prodbox cluster reconcile` brought up the platform (host-fit `host_capacity` on the real 238 GiB single-disk host — `RESOURCE_HOST_CAPACITY` ok at ephemeral 44280 + durable 182030 Mi; Bootstrap→Vault init→auto-unseal from the durable MinIO unlock bundle, 75-step Vault bootstrap `status:ready`; gateway full-mode; MetalLB/Envoy/Percona-operator/cert-manager/MinIO/registry). `prodbox test integration keycloak-invite --substrate home-local` then materialized `aws.*` from the `aws_admin_for_test_simulation` fixture, force-synced the in-force SSoT, and `--with-edge` deployed the **complete canonical workload set** (gateway, keycloak, keycloak-postgres = 3-node Percona/Patroni HA, vscode, api×2, redis, websocket×2 — all Running) with real Route 53 DNS and a **real ZeroSSL public-edge TLS cert** (`public-edge-tls` Ready=True; served cert `issuer=O=ZeroSSL GmbH … CN=test.resolvefintech.com`, valid Jul 9–Oct 7 2026). Live edge probes over MetalLB `192.168.2.240`: `/vscode`→302 login-redirect, `/api`→401 JWT-required, `/ws`→401, `/minio`→302, all `ssl_verify_result=0`. SES provisioned + semantic readiness (sender/MX/receipt-rule/capture Ready). Postflight cleaned up (`USER_DELETED=true`, `aws.*` cleared, per-run stacks destroyed). **Two honest caveats:** (1) the run exited 1 at the post-test restore step `RestoreNodePrepareRetainedSes` on a transient in-cluster MinIO connectivity blip (`127.0.0.1:39000` unreachable) during SMTP-target materialization; (2) **the gateway heap-leak is reproduced live** — the `LegacyModelBEmitter` daemon OOM-cycles on its ~460 MiB cgroup limit (gateway-node-b restarted 3× in 67 min; dmesg `Memory cgroup out of memory: Killed process … (prodbox)`), which is the plausible cause of the restore-phase blip and remains the blocker for long-run stability / Standard-P qualification. This is a **Standard-O live proof of the current baseline's deploy path**, not deployment qualification (Standard P) and not a cutover to the new control-plane roles (whose production wiring is unwritten). |
| 2026-07-29 | Sprint `4.50` 🔄 **Active — Increment DD (the greenfield fenced Provider Worker algebra + interpreter) landed** — `providerWorkerInterpreter` brings the Provider Worker to full interpreter parity, so **four of five** control-plane roles now dispatch every owned route through `serveControlPlaneRequest`; only the Target Secret Agent `complete` arm (deliberately opaque — Standard-O agent binding) keeps its role fail-closed. New pure modules `Prodbox.Lifecycle.ProviderWorker.ProviderWork` (algebra) and `Prodbox.ControlPlane.ProviderWorkEndpoint` (wire/handlers/projections). The fence is structural (a closed `ProviderIntent` sum — registered-stack reconcile/observe/read-back, bounded scratch checkpoint, and the operator-selected fenced `aws-ses` non-credential inventory: sending identity/DKIM/receipt rules/capture bucket — cannot represent a credential IAM identity/key, admin/credential permit, Authority write, backup/TLS identity, target secret, Gateway/DNS election, or SMTP IAM principal/policy/key) and dynamic (`decideProviderWork` refuses unregistered/stale-revision/expired, admits ≤1 intent at a time, idempotent resubmit = no second admission, single-narrow-session idle→in-flight→close plus canceled/expired→recovery→grace→successor). Evidence: algebra 15/15, endpoint 10/10, interpreter 6/6 (role-interpreters 23/23, Sprint 4.50 aggregate 176/176), `prodbox dev check` exit 0 (warning-clean, fourmolu, HLint, conformance). Real narrow-session provider execution + retained-store CAS are the Standard-O follow-ons; Sprint `4.50` stays Active. |
| 2026-07-29 | Sprint `4.50` 🔄 **Active — Increment CC (the Authority Backup role interpreter) landed** — `authorityBackupInterpreter` brings Authority Backup to full interpreter parity with the Lifecycle Authority and TLS Retention roles, so three of the five control-plane roles now dispatch every owned route through `serveControlPlaneRequest`. The `copy` arm was already landed (Increment Y's `serveBackupCopyRequest` over the shared codec); this adds the `observe` arm's `(status, summary)` projection — `authorityBackupObserveStatus` (always `200`) + `authorityBackupObserveSummary` (exhaustive over `AuthorityAdmissionState`) — and binds both routes over the injected `AuthorityBackupRepository`, proven by an in-memory fixture driving `copy`→freeze, `observe`→committed-freeze, malformed→`400`, foreign-route→`404`, and the readiness probe. Only the Target Secret Agent `complete` arm (deliberately opaque — Standard-O agent binding) and the greenfield Provider Worker algebra keep their two roles fail-closed. Evidence: role-interpreters 17/17, Authority Backup endpoint 15/15, `prodbox dev check` exit 0 (warning-clean, fourmolu, HLint, conformance). Supplying the concrete retained-store CAS repository and installing the interpreter in `runControlPlaneRole` over a real socket remain the Standard-O follow-ons; Sprint `4.50` stays Active. |
| 2026-07-28 | **Sprints `1.72`/`1.73` LANDED — Phase 1 reclosed; the Ring-1 Dhall over-commit shim and host-fitting `config generate` are built.** `renderProjectConfigDhall` now lean-emits the `concurrentPlanDraws` as data and inlines the capacity lemmas so the generated `prodbox.dhall` carries `let _ = assert : planFits === True in cfg`; an over-committed hand-edit (shrunk host / inflated reservation) fails Dhall type-check and no longer loads through `decodeProjectConfigDhall`, one ring ahead of the Haskell gate, while a valid file round-trips unchanged (the lemmas and assert normalize away for `Dhall.auto` extraction). `config generate` observes the host (`nproc` / `/proc/meminfo` / `df -Pm`) and derives a `host_capacity` that covers demand and fits the device — failing fast when the host is too small — with `--portable` for host-agnostic generation (the image build); the reader was factored into the Phase-1-owned `src/Prodbox/Capacity/HostProbe.hs`, shared with Sprint `4.52`'s Ring-3 reconcile reader (forward-consumed, Standard N). This closes the live incident where a fixed 280 GiB default `host_capacity` exceeded the 238 GiB machine. Evidence: `test/unit/Tier0PlanAssert.hs` 3/3, parser round-trip + observation-parser tests, live host-fit `config generate`/`config validate` + a rejected over-committed edit on this host, and `prodbox dev check` exit 0. `Deployment qualification: pending` (Standard-P resource-envelope surface). |
| 2026-07-25 | **Resource-governance doctrine adopted — Phases 1/3/4 reopened on their own resource surfaces (docs authored ahead of code).** A live-surfaced storage landmine (deriving a namespace `requests.storage` quota from the placeholder `durable_storage_mib` would cap keycloak at 6Gi while its Postgres PVCs need 60Gi → PVCs refused) generalized into a doctrine: *one value, one proof, unrepresentable over-commit across cpu/ram/storage*. Honest three-ring boundary ([resource_scaling_doctrine.md § 2C](../documents/engineering/resource_scaling_doctrine.md)) — Dhall is a defense-in-depth generator cross-check (no refinement types), the **Haskell decode gate** is where over-commit is truly unrepresentable (the `AllocatedResourcePlan` proof becomes a required field of `ValidatedSettings`), and the observed host is re-proved at reconcile (dual-device durable vs ephemeral). New sprints, dependency-ordered **`3.28`→`1.69`→`3.29`→`4.52`→`3.27`** (+`1.70`): `3.28` one shared `Capacity.Render`; `1.69` the decode gate + `planAllocatable`/`planTotalDraw` projections (retiring `validateResourcePlan`); `3.29` durable PVC size single-sourced from `durable_storage_mib` (quota/size-neutral — authored durable quotas already equal real PVC totals); `4.52` observed-host `compileResourcePlanAgainstObserved` (deleting `hostCapacityCoversPlan` + both `clusterAllocatable`); `3.27` derived quotas via `planNamespaceQuota`/`renderedNamespace`/`WorkloadConcurrency` (deleting authored `namespace_quotas`); `1.70` `GuaranteedEnvelope` via `WorkloadQoS`. Reconciled: the 3-axis `CapacityBudget` **stays** (live in `Capacity.Storage`/`Scaling.Autoscaler`); only unused `MilliCpu`/`MebiBytes` retire. DAG roots `3.28`/`1.69` were 📋 Planned and `1.70`/`3.29`/`3.27`/`4.52` were ⏸️ Blocked on their earlier-or-same-phase code prerequisites **as of this dated entry**; all six are ✅ Done today (status corrected in place 2026-08-11 — a dated narrative row stating a status in the present tense reads as a competing ledger). `Deployment qualification: pending` (resource-envelope/persistence/topology surface). |
| 2026-07-25 | **Sprint `1.68` LANDED — Phase 1 reclosed; over-commitment now unrepresentable in code.** The opaque proof-carrying `AllocatedResourcePlan (c :: Certification)` and its total `compileResourcePlan` landed in the new `src/Prodbox/Capacity/Allocation.hs` (DataKinds phantom + `SCertification` singleton + `SomeAllocatedPlan`; hidden-constructor `HostCapacity`/`ClusterBudget`/`WorkloadAllocation`/`CertifiedWorkload`), the non-saturating `resourceVectorSubtractChecked` + extracted `validateRawResourcePlanShape` in `Capacity/Config.hs`, the `GuaranteedEnvelope`/`mkGuaranteedEnvelope` (`request == limit`) witness, and the `runConformanceTier` over-commit gate (`resourcePlanOverCommitViolations`) in `CheckCode.hs`. Evidence: `prodbox dev check` exit 0 (warning-clean `-Werror` build, fourmolu, HLint, conformance incl. the new gate); 18/18 `test/unit/Allocation.hs`; the `validateResourcePlan` over-commit lemmas green (the `workloadOverQuotaPlan` fixture retargeted to the `api` namespace under the co-located `concurrentNamespaceQuotas` fold). `prodbox-config-types.dhall` unchanged (the proof is not Dhall-facing). Consumer Sprints `3.27`/`4.52` are now **📋 Planned** (unblocked). Two pre-existing `test/unit/Main.hs` rendered-quota assertions still encode pre-`2026-07-25` vscode values and are owned by Sprint `3.27`'s derived-from-draw refactor. Deployment qualification stays `pending` (Standard-P resource-envelope surface). |
| 2026-07-25 | **Resource-model over-commitment made unrepresentable — Phase 1 reopened on Sprint `1.68` (own-surface, Standard A/N), with consumer Sprints `3.27`/`4.52`.** A live `test all --substrate home-local` gateway CPU-throttle counterexample — the gateway pinned at its 750m limit, ~93% cgroup throttle, periodic RTS heap-overflow — **passed every capacity validation yet still failed at runtime**, proving the runtime-`Either` capacity model still lets an illegal state be represented. The refactor moves the `host ≥ cluster ≥ Σworkloads` nesting into an opaque proof-carrying `AllocatedResourcePlan` (total `compileResourcePlan`, matching `ServiceCapacityPlan`/`RuntimeMemoryPlan`): a non-saturating `resourceVectorSubtractChecked` replaces the saturating budget subtraction; namespace `ResourceQuota`s become **derived** projections of workload draws (retiring authored `namespace_quotas`/`concurrentNamespaceQuotas`/the keycloak↔vscode hand-fold); (b) `cluster ≤ host` is closed at reconcile against **observed** host facts; a `GuaranteedEnvelope` witness catches mis-authored QoS; a `dev check` gate fails the build if `defaultResourcePlan` over-commits. Memory-(c) is already structural via `RuntimeMemoryPlan`; CPU-(c) stays a non-erasable `uncertified-until-first-profile` seam (Sprint `5.21`). Docs authored ahead of code — sprints `Planned`/`Blocked`, `Deployment qualification: pending`. |
| 2026-07-25 | **Live-surfaced vscode-namespace capacity regression FIXED (home qualification, 3rd blocker past gateway+SES).** With the gateway + SES fixes, the home `test all` reached the workload-chart deploy, where the vscode pod was refused: `FailedCreate ... exceeded quota: vscode-resource-quota, used=1725m, limited=1300m`. Root cause: the supported runtime deploys Keycloak + its 3-instance keycloak-postgres **co-located in the vscode namespace** (confirmed: one keycloak, one `prodbox-vscode-pg` cluster-wide, empty `keycloak` namespace), and `concurrentNamespaceQuotas` already documents/excludes that co-located shape from the single-node budget — but the Sprint 1.65/3.26-C vscode-quota trims (2425→1400→1300m) sized the **rendered** ResourceQuota for vscode *alone*, leaving no headroom to admit the co-located Keycloak. Fix (`src/Prodbox/Capacity/Config.hs`): fold the standalone `keycloak` allowance into the vscode NamespaceQuota (1300→3325m CPU) so Pods admit, and subtract that same allowance back out of the vscode contribution in `concurrentNamespaceQuotas` — **budget-neutral** (the single-node concurrent sum is unchanged; Keycloak still counted exactly once). Evidence: `prodbox dev check` exit 0 (`validateResourcePlan` holds, config drift clean, guardrail goldens unbroken). **Live re-validation** (vscode Pod admits) is the pending Standard-O axis on the next `test all --substrate home-local`. |
| 2026-07-24 | **Live-surfaced SES lease-session IAM gap FIXED (home substrate qualification, next blocker past the gateway).** With the gateway deadlock cleared, the home `test all` progressed through platform + gateway (full-mode) + workload-chart deploy and reached the `aws-ses` reconcile, which failed: the lease-session role (`prodbox-ses-lease-session`) inline policy granted object CRUD but not the S3 **tagging** actions that Pulumi's `aws:s3:BucketObjectv2` performs on every refresh of the capture-readiness probe object → `403 AccessDenied` on `GetObjectTagging` → `pulumi up failed` / `captureReadinessObject creating failed` / `LeaseExecutionActionFailed`. Fix: add `s3:GetObjectTagging` + `s3:PutObjectTagging` to `s3ObjectLifecycleActions` in `src/Prodbox/Infra/AwsSesLeaseRole.hs`. Evidence: warning-clean build; `dev check` (in flight). **Live re-validation** (re-provision the lease role + `aws-ses` reconcile succeeds) is the pending Standard-O axis on the next `test all --substrate home-local`. Advances Phase 8 (SES) bootstrap correctness. |
| 2026-07-24 | **Live-surfaced gateway pre-Vault bootstrap deadlock FIXED + live-proven (home substrate).** The first live `prodbox test all --substrate home-local` exercise of the composed, never-live-validated Sprint `2.32`/`2.34`/`3.26-E`/`3.26-G` gateway (single-writer emitter + fail-closed `/readyz` + Deployment→StatefulSet + 2-node) deadlocked: the gateway chart's `helm --install --wait` blocked on the StatefulSet readiness probe, which was `/readyz` (Sprint 2.34) — **503 by design in the degraded pre-Vault mode** — so the daemon was pulled from its Service and unreachable, and the lifecycle could never drive Vault unseal (`helm ... context deadline exceeded`; Vault stayed `Sealed/Initialized=false`). Fix: kubelet readiness probe `/readyz`→`/healthz` in `src/Prodbox/Gateway/Probe.hs` (process reachability; the degraded pre-Vault daemon stays in-Service so the NodePort unseal call reaches it — full `/readyz` object-store readiness remains the lifecycle `ComponentGatewayDaemonFull` gate, and clients + the emitter Lease still fence degraded serving), and the pre-Vault gate `DeploymentAvailable`→`StatefulSetReady gateway-<node>` in `src/Prodbox/CLI/Rke2.hs` (matching the 3.26-E StatefulSet). Regenerated `charts/gateway/values.yaml` + golden + `GatewayProbe` test + CheckCode message. Evidence: `prodbox dev check` exit 0; 92/92 targeted tests; and **live** — the fixed `cluster reconcile` deployed the gateway (`deployed`, pods `1/1` Ready via `/healthz`) and **Vault unsealed** (`Sealed false`), progressing past the prior deadlock. Corrects Sprint `2.34`/`3.26-E`. |
| 2026-07-24 | Sprint `4.51` 🔄 **Active — Increment B Stage B (the shared host-direct/gateway Model-B transport seam) landed** — `src/Prodbox/Lifecycle/ModelBCasTransport.hs` (`ModelBTransport` + `modelBCasAdapterOverTransport`) is the ONE Model-B ↔ authority-object translation both retained-authority transports now delegate to: `gatewayModelBCasAdapter` (refactored to a thin gateway-HTTP transport, signature unchanged) and the new `src/Prodbox/Lifecycle/HostDirectAuthorityStore.hs` `hostDirectModelBCasAdapter` (`'ClusterRetained`, over the Stage-A `AuthorityObjectCore` host-direct primitives). This extends Stage A's structural byte-compat one level up — coordinate-authority guarding, encode/decode, and every observation/response mapping exist exactly once, so the two transports cannot silently diverge. `test/unit/HostDirectModelBAdapter.hs` (11 cases) drives the shared adapter over the same in-memory conditional-put fake (+ a `'ClusterRetained` type witness). Evidence: `prodbox dev check` exit 0 (warning-clean, fourmolu, HLint, conformance); 11/11 new + existing suites unaffected. Remaining 4.51-B is Stage D (the atomic gateway retype + live `AwsSesStack` transaction cutover + `OperationRecord` + lease-bracket dissolution) — Standard-O, provable only by a live `prodbox test all --substrate aws` — and the trivial Stage E escape-registry reclassify. |
| 2026-07-24 | Sprint `4.48` 🔄 **Active — Increment I (the deterministic crash/restart outbox interpreter) landed** — `src/Prodbox/Lifecycle/Authority/OutboxSim.hs` is the pure fake-capability crash/restart reference interpreter the 4.48 Independent Validation calls for: it composes the durable operation journal + `decideOperationRecovery` over an in-memory substrate (journal + keyed effect target with an apply-counter), with no object store/Vault/clock/AWS/K8s. `armOperation` journals intent before effect; `runEffect` applies+completes; `armAndApply` stages the "crash after effect, response lost" case; `recoverOperation` re-observes and executes (source current), recovers WITHOUT re-applying (apply-counter stays 1 — at-most-once), or fails closed (diverged). Evidence: `prodbox dev check` exit 0; `LifecycleAuthorityOutboxSim` 7/7 (full `LifecycleAuthority*` suite now 77/77). |
| 2026-07-24 | Sprint `4.48` 🔄 **Active — Increment H (the in-force-config propose-CAS fold) landed** — `src/Prodbox/Lifecycle/Authority/Config.hs` owns the in-force configuration as a monotone generation (`ConfigGeneration`/`ConfigSchemaVersion`/`ConfigDigest`/opaque `ConfigReference`), seeded once from the bounded Tier-0 boot projection and advanced only by CAS. `decideConfigPropose`/`applyConfigPropose`/`stepConfigPropose` refuse unsupported schema, CAS-before-seed, re-seed-after-seed, and a mismatched expected-prior; re-proposing the in-force schema+digest is an idempotent no-op (response-loss safe). `observeInForceConfig` serves the current generation; encryption and role-scoped projection of the referenced blob remain the interpreter's. Evidence: `prodbox dev check` exit 0; `LifecycleAuthorityConfig` 8/8 (full `LifecycleAuthority*` suite now 70/70). This completes the pure authority-core Deliverables (Increments A–H); the remaining 4.48 work is the byte-compat live-transaction cutover + physically-separate interpreters. |
| 2026-07-24 | Sprint `4.48` 🔄 **Active — Increment G (the versioned TLS-retention promotion/restore fold) landed** — `src/Prodbox/Lifecycle/Authority/TlsRetention.hs` closes Validation item 7. A `RetainedTlsRef` binds the immutable `RetentionVersion` + cert serial/SPKI/`notAfter` + ciphertext/wrapped-DEK digest + source Secret UID/resourceVersion. `decideTlsPromotion`/`applyTlsPromotion`/`stepTlsPromotion` CAS-promote only after source re-observation + Adapter byte read-back, refusing stale/out-of-order version, validity regression, and unapproved key change; the exact current version is an idempotent no-op (response-loss safe). `decideTlsRestore` applies the exact committed reference on an intact read-back (never S3 latest), issues only on positive absence or trusted-time expiry, and fails closed on corrupt/mismatched/unobservable state. Evidence: `prodbox dev check` exit 0; `LifecycleAuthorityTlsRetention` 10/10 (full `LifecycleAuthority*` suite now 62/62). |
| 2026-07-24 | Sprint `4.48` 🔄 **Active — Increment F (the disjoint admin-action permit acceptance fold) landed** — `src/Prodbox/Lifecycle/Authority/AdminAction.hs` closes Validation item 6: the disjoint `AdminAction` family (`DestroyAwsSes`/`MigrateLegacyBackend`/`ReconcileQuota`) excludes provider/credential/decommission actions by construction; an `AdminActionPermit` names its audience `RunnerRole` + single bound action. `decideAdminPermit`/`applyAdminPermit`/`stepAdminPermit` accept only the `AdminActionRunner` audience + the instantiated action + a fresh permit, exactly once; cross-role/cross-action permits refused (audience/action before state), expired refused, consumed-nonce replay idempotent (response-loss safe), divergent-nonce-after-consumption conflict. Evidence: `prodbox dev check` exit 0; `LifecycleAuthorityAdminAction` 8/8 (full `LifecycleAuthority*` suite now 52/52). |
| 2026-07-24 | Sprint `4.48` 🔄 **Active — Increment E (the idempotent operation-submission front-door) landed** — `src/Prodbox/Lifecycle/Authority/Submission.hs` is the pure, standalone submission ledger closing Validation items 1–2: an `OperationId` binds the admitting `AuthorityEpoch` + `(client, client-sequence, request-digest)`; `decideSubmit`/`applySubmit`/`stepSubmit` accept a fresh submission, return the SAME id on an exact resubmission (a lost response converges by id, never a second operation), refuse a sequence reused with a different digest, refuse at live-population capacity, and return expired for a sequence at/below the compacted per-client floor. `cancelSubmission`/`completeSubmission` settle in-flight submissions idempotently (cancel-after-complete / complete-after-cancel refused); `compactClientTerminalsBelow` advances the floor and drops settled tombstones (refusing across an in-flight submission); `submissionStatus` reports in-flight/settled/expired/unknown. A client disconnect never determines an outcome (cancellation is an explicit command; no disconnect input). Evidence: `prodbox dev check` exit 0; `LifecycleAuthoritySubmission` 10/10 (full `LifecycleAuthority*` suite now 44/44). Remaining 4.48 unchanged: the host-direct interpreter + `Lease*`/`CheckpointAuthority*`/`TargetCommit*` migrations (byte-compat cutover, coupled to Sprint `4.51` Increment B) and the physically-separate Backup/TLS/Provider interpreters. |
| 2026-07-24 | Sprint `4.48` 🔄 **Active — Increment D (the pure post-genesis backup-repair reopen fold) landed** — `src/Prodbox/Lifecycle/Authority/BackupRepair.hs` is the ONLY post-genesis, primary-only fold over the shared `AuthorityAdmissionState` (now carrying `BackupRepairFrozen !AuthorityEpoch !BackupRepairProgress`): a temporary/unobservable backup outage freezes admission and merely waits (no permit, no external effect), reopening under a strictly greater epoch only once the backup reads healthy again; a positively-absent key/bucket or proven policy drift primary-journals a signed one-time `BackupRepairPermit` (replay idempotent, divergent permit refused), then reopens under `nextAuthorityEpoch` after BOTH the next `LongLived` generation receipt AND the adapter's first new backup receipt read back. Total `decideBackupRepair`/`evolveBackupRepair`/`backupRepairDecisionEvents`/`stepBackupRepair` mirror the genesis fold and compose into the `AuthorityState` aggregate (new `AuthorityBackupRepair` command/decision/event arms) so admission is frozen for the whole repair and a post-repair operation is fenced under the greater epoch. Evidence: `prodbox dev check` exit 0; `LifecycleAuthorityBackupRepair` 12/12 + the full `LifecycleAuthority*` suite 34/34. Remaining 4.48: the host-direct interpreter binding operation records to the three `'ClusterRetained` projections + the `Lease*`/`CheckpointAuthority*`/`TargetCommit*` migrations (the byte-compat-critical live-transaction cutover, coupled to Sprint `4.51` Increment B), plus the physically-separate Backup/TLS/Provider interpreters. |
| 2026-07-23 | Sprint `4.48` 🔄 **Active — Increments A + B + C landed; Phase `4` opens on `4.48`** — **C** (aggregate): `src/Prodbox/Lifecycle/Authority/State.hs` composes the genesis fold with the operation journal — `AuthorityState` holds the admission state + one `FencedOperation` per binding, with total `decideAuthority`/`evolveAuthority`/`stepAuthority` (fully event-sourced); normal operations are admission-gated + epoch-fenced, idempotent (`AlreadyArmed`/`AlreadyComplete`) and conflict-checked; `LifecycleAuthorityState` 6/6. Earlier: — **A** (genesis admission fold): `src/Prodbox/Lifecycle/Authority/Genesis.hs` is the pure `GenesisFrozen → EstablishAuthorityBackup → BackupEstablished` fold (`AuthorityAdmissionState` + command/decision/event ADTs with total `decideGenesis`/`evolveGenesis`/`stepGenesis`, modeled on `ControlPlane.Capacity`), enforcing that normal admission opens ONLY after BOTH the home Target Agent generation receipt AND the Authority Backup Adapter receipt are read back, under the genesis `AuthorityEpoch`; out-of-phase commands are refused, the plan is idempotent (divergent plan refused), events replay idempotently. **B** (durable operation journal / outbox): `src/Prodbox/Lifecycle/Authority/Operation.hs` is the polymorphic `OperationRecord binding intent result` with an append-only `OperationArmed → OperationCompleted` phase (`newArmedOperation`/`resumeOperation`/`completeOperation`, terminal at-most-once) and `decideOperationRecovery` — authorizing execution only when the source is provably current, recovering (never repeating) a matching applied effect, and failing closed on a mismatched/diverged/unobservable target; it generalizes `Broker.RequestJournal`. Unblocked by Sprint `3.26`'s landed control-plane charts. Evidence: `prodbox dev check` exit 0; `LifecycleAuthorityGenesis` 8/8 + `LifecycleAuthorityOperation` 8/8. Remaining 4.48: the `AuthorityState` aggregate over the three retained projections, the host-direct interpreter (on `AuthorityObjectCore` + `ControlPlane.AuthorityClock`, replacing the gateway-hosted transport/clock), the `BackupRepair` reopen, and the `Lease*`/`CheckpointAuthority*`/`TargetCommit*` migrations. |
| 2026-07-23 | Sprint `3.26` 🔄 **Active — Increment H (the five standing control-plane role charts) landed** — `charts/{lifecycle-authority,provider-worker,authority-backup,tls-retention,target-secret-agent}/` are rendered as internal control-plane charts (chart-only `ComponentGraph` nodes behind the registry, off `supportedChartNames`, no native install step, so the production `cluster reconcile` topology is unchanged). Lifecycle Authority is a StatefulSet with a retained journal `volumeClaimTemplate`; the other four are Deployments. Each has its own compiled `Prodbox.Lifecycle.<Role>.ChartStatics` projecting a new least-privilege `VaultRoleId` (the closed inventory is now 7 roles, collision-free under `vaultIdentityRegistryViolations`) and constant-time `/healthz`+`/readyz` probes, drift-gated byte-for-byte against `values.yaml`. `ChartPlatform` gains `controlPlaneRoleChartNames`, a shared `valuesForControlPlaneRole` + 5 wrappers, `resolveChart`/runtime-image/`chartResourceProfiles` entries; the capacity plan reserves 5 independent namespace quotas + Guaranteed-QoS profiles funded by Increment G (concurrent sum `6130m / 12736 MiB ≤ 6500 / 12800`); the six `ComponentId` exhaustive-match sites + the `TestSupport` Dhall mirror + `prodbox-config-types.dhall` are regenerated. Evidence: `prodbox dev check` exit 0; targeted capacity/ComponentId-bijection/chart-statics suite 248/248 + the graph test proving `resolveDependencyOrder` for each new chart = `[<chart>]`; `helm template` of all 5 charts (6 objects each). Remaining 3.26: each role's least-privilege Vault policy/consumer/seed object (co-lands with the 4.48 credential flow) + per-role negative-lint fixtures; the permit Jobs co-land with 4.48; the pre-Vault cutover is Standard-P (with 4.50). Live rollout is a non-blocking Standard-O proof. |
| 2026-07-23 | Sprint `3.26` 🔄 **Active — Increment G (control-plane capacity funding via the operator-approved home gateway 3 → 2 reduction) landed** — the maxed single node (i7-4790K: 8 threads / ~15.5 GiB; `host_capacity` already claims the whole machine) is funded for the standing control-plane workloads by running two home gateway emitter identities instead of three. `Prodbox.Lib.ChartPlatform.gatewayNodeIds` becomes the substrate-aware `gatewayNodeIdsForSubstrate` (home `[node-a, node-b]`, AWS `[node-a, node-b, node-c]`), so AWS keeps three identities and its Sprint-7.28 static retained-EBS provisioning unchanged; the `gateway` namespace quota drops `2750m → 2000m` / `3584 → 3072 MiB` and the `gateway` workload profile drops `replicas 3 → 2`, freeing `750m CPU / 512 MiB` (new concurrent sum `5700m / 12256 MiB ≤ 6500m / 12800 MiB`, headroom `800m / 544 MiB`). Because the daemon rejects any `event_keys` set that does not match Orders membership exactly (`compileBoundedOrders`), `charts/gateway/templates/configmap-config.yaml` now renders `event_keys` parametrically over `nodes.rankedIds` (retiring the hard-coded three-node mesh + `eventKeyNode{A,B,C}`). Evidence: `prodbox dev check` exit 0; targeted capacity / resource-plan / guardrail-golden / `gatewayDaemonWorkloadRefs` / emitter-persistence / Orders suite 204/204; `helm template` of the gateway config on the home two-node case (exactly a two-member `event_keys` list). Full `prodbox test unit` is environment-flaky on this host (daemon/concurrency tests hang under fd pressure), so the code-owned surface is validated with `dev check` + targeted `-p` per the validation-toolchain guidance. Remaining 3.26 (below): the five standing control-plane charts + Vault identities + graph nodes + capacity profiles + lint; permit Jobs co-land with Sprint 4.48; the pre-Vault cutover is Standard-P (sequenced with 4.50). The **live** two-emitter StatefulSet rollout is a non-blocking Standard-O proof. |
| 2026-07-21 | Sprint `3.26` 🔄 **Active — Increments B + C + D + E + F (Bootstrap Broker chart + capacity/render + reconcile-graph wiring + Gateway StatefulSet + Vault identity-registry cross-check) landed** — the physically separate broker is rendered as `charts/bootstrap-broker/`: a single-writer `Deployment` (replicas 1, `Recreate`) running `bootstrap-broker start` as its own ServiceAccount (`.Values`-driven from the compiled statics), a loopback-oriented ClusterIP `Service`, a `bootstrap-broker-isolation` `NetworkPolicy` whose egress is limited to DNS + Vault (`:8200`) + object store (`:9000`) with no mesh/KV/Pulumi/SES/authority-CAS/target-secret egress (Sprint `2.33` route boundary), a `PodDisruptionBudget`, a Guaranteed-QoS envelope, and constant-time `/healthz`/`/readyz` probes. **B**: `CheckCode.hs` registers the `bootstrap-broker-chart-statics.values` generated section (drift-gated by `dev check`) plus a `bootstrap-broker`-guarded chart lint forbidding raw identity/probe literals; `BrokerChartStatics.hs` grows to 11 cases. **C**: the typed `capacity.resource_plan` gains a dedicated `bootstrap-broker` namespace quota + Guaranteed-QoS workload profile, funded by an operator-approved vscode-ceiling trim (1400m → 1300m, draw stays 800m; concurrent sum 6450m ≤ 6500m); `ChartPlatform.hs` gains `valuesForBootstrapBroker`, a `resolveChart` arm, and the camelCase `bootstrapBroker` `chartResourceProfiles` mapping. **D**: `ComponentGraph.hs` gains `ComponentChartBootstrapBroker` (an internal chart-only node behind the registry) with its full bijection + `componentCapabilityOp` + the exhaustive-match cases across `stepsForComponent` / `AwsSubstratePlatform` / operator-gate + readiness registries — each chart-only, so the broker contributes **no** native install step and the production `cluster reconcile` topology is unchanged; the runtime-image resolver learns the broker; `resolveDependencyOrder "bootstrap-broker"` now yields `["bootstrap-broker"]` so the plan builder drives it end-to-end. Making Vault-unseal depend on the broker (sole pre-Vault unsealer) is a **Standard-P cutover**, deliberately not done. **E** (Gateway Runtime StatefulSet): `charts/gateway/templates/deployments.yaml` now renders one stable `gateway-<nodeId>` StatefulSet per ranked id (replicas 1) consuming the Sprint-2.32 `emitterPersistence` projection by index — each mounts its registered retained emitter journal at `/var/lib/prodbox/gateway-emitter` (home node-pinned `hostPath` / AWS `ReadWriteOncePod` retained-EBS `volumeClaimTemplate`); a single-replica STS update deletes the old pod before creating its replacement (no two-writer overlap per identity); `rbac.yaml` adds a namespace-scoped `coordination.k8s.io` Lease Role/RoleBinding for the incarnation fence; and `Rke2.gatewayDaemonDeploymentRefs` → `gatewayDaemonWorkloadRefs` targets `statefulset/gateway-<node>` for rollout restart/status. `prodbox-config-types.dhall` was regenerated for the new capacity default and graph. Evidence: `prodbox dev check` exit 0, full `prodbox test unit` 2207/2207 (of 2208; one pre-existing env-flaky AWS-SSH test excluded, passes in isolation), integration cli 52/52, integration env 52/52, the broker suite 11/11, the `prodbox-haskell-style` meta suite 18/18, and an in-session `helm template` of the gateway chart on both substrates (home hostPath + AWS `volumeClaimTemplate`, exit 0). A pre-existing test-helper lock flake (`withBinarySiblingTier0` lazy read) was fixed en route (strict `readFile'`). The **live** gateway StatefulSet/PV-bind/Lease rollout is a non-blocking Standard-O proof (cleared by `prodbox test all`). **F** (Vault identity-registry cross-check): `Prodbox.Secret.VaultInventory.vaultIdentityRegistryViolations` is a compiled invariant proving every Vault Kubernetes-auth role name and chart-secret policy name is bound by exactly one identity across BOTH the cross-module `VaultRoleId` registry and the data-driven consumers (the previously-unenforced § 10.2 "exist exactly once" invariant), enforced by a unit test AND the `dev check` conformance tier. Remaining increments: the Standard-P pre-Vault cutover, and the other control-plane roles (Lifecycle Authority, Backup/TLS adapters, Provider Worker, Target Agent, permit Jobs) — whose least-privilege consumers are coupled to the Phase-4/8 credential-flow field schemas (seed objects) and whose workload charts each need an operator capacity-architecture decision on the maxed single-node budget, so they are best landed alongside their Phase-4 interpreters. |
| 2026-07-21 | Sprint `3.26` 🔄 **Active — Increment A (Bootstrap Broker workload identity) landed** — the first increment of physical control-plane separation. `Prodbox.Vault.RoleId` gains `VaultRoleBootstrapBroker`, a bootstrap-only Vault Kubernetes-auth role (`prodbox-bootstrap-broker`) distinct from the Gateway Runtime's `prodbox-gateway-daemon`, plus `allVaultRoleIds`; and `src/Prodbox/Bootstrap/Broker/ChartStatics.hs` is the one compiled source of the physically separate broker workload's static identities — its Pod ServiceAccount (= the bootstrap-only Vault role) and its constant-time liveness/readiness probe paths projected from the closed `BrokerRoute` registry (`/healthz`, `/readyz`), with aeson + generated-YAML projections; the broker's listen port stays deployment configuration, deliberately not a compiled static. `test/unit/BrokerChartStatics.hs` proves the broker/gateway identity distinctness (anti-shared-identity invariant), all-roles-name-distinct, and route-sourced probes. Evidence: `prodbox dev check` exit 0 and the new `Sprint 3.26 compiled Bootstrap Broker chart statics` suite 5/5. Remaining increments render the workload templates (Deployment/StatefulSet/Service/NetworkPolicy/PDB), resource envelopes, and the other control-plane roles (Lifecycle Authority, Target Secret Agent, Backup/TLS adapters, Provider Worker, permit Jobs, Gateway StatefulSets) with least-privilege Vault policies and negative-lint fixtures. |
| 2026-07-21 | Sprint `2.33` ✅ **Done; Phase `2` reclosed** — pre-Vault recovery is extracted into a minimal Bootstrap Broker. A closed `RuntimeRole` split (`src/Prodbox/Runtime/Role.hs`) gives the `bootstrap-broker` and `gateway-runtime` roles each their own mounted Dhall with no shared daemon config; the `src/Prodbox/Bootstrap/Broker/` subsystem exposes a closed `BrokerRoute` registry limited to bounded init/unseal/seal/status/rotation, allowlisted baseline reconcile, bounded PKI status/test-issuance, and child custody/recovery (no generic KV/mesh/DNS/Pulumi/SES/authority-CAS/target-secret route); the prepared-init PGP-recovery/password-AEAD custody protocol (burn-recipient initial token never decrypted; accessor-audited short-lived root session revoked and proven absent) carries a full crash/resume matrix; the pre-Vault handlers are removed from `Gateway/Daemon.hs`/`Gateway/Client.hs` and the `vault ...` CLI compiles into broker-mediated programs; and a `checkBootstrapBrokerIsolation` `dev check` lint fails the build on a reintroduced pre-Vault route in the Gateway registry or a generic object-store escape in the Broker registry. Post-unseal handoff is an observed transition, not the broker becoming the Lifecycle Authority. Evidence: `prodbox dev check` exit 0, `prodbox test unit` 2193/2193 (incl. the ten `BootstrapBroker*` suites), integration CLI 52/52, integration env 52/52, and `prodbox-daemon-lifecycle` 28/28. Standard P keeps the production gateway on `LegacyModelBEmitter`; the composed real-cluster bring-up is the non-blocking Standard-O live-proof axis, Sprint `3.26` (now unblocked) owns the physical workloads, and both deployment-qualification rows remain pending. |
| 2026-07-20 | Sprint `2.32` ✅ **Done on the code-owned target; Phase `2` remains open on Active Sprint `2.33`** — the mutually exclusive `JournalLeaseEmitter` path composes one bounded actor per emitter, an encrypted identity-bound local journal, journal-first admission, exact recovery rewind/republication, current Kubernetes Lease/incarnation fencing, durable per-peer acknowledgements and checkpoint compaction, authenticated Orders migration with a projection-retained prior digest, operation-specific capacity-one target lanes, and the typed substrate-exact persistence projection. A migrated-projection crash before publication restarts through ordinary durable recovery, re-arms the exact prior-Orders admission, and converges without relabeling retained bytes. Local restart restores only from the journal's authenticated floor/suffix; peer repair remains a remote-replica mechanism. Evidence: full unit 1974/1974, full `prodbox-daemon-lifecycle` 28/28, integration CLI 49/49, integration env 49/49, the fresh exhaustive 16-invariant TLA+ run (7,139,920 generated / 781,710 distinct, depth 44, queue 0), docs check/lint, `git diff --check`, and final-tree `prodbox dev check` exit 0. Standard P keeps `runGatewayDaemon` on `LegacyModelBEmitter`; physical StatefulSet/PV/EBS consumption belongs to Sprint `3.26`, live proof and both deployment-qualification rows remain pending, and no operational cutover is claimed. |
| 2026-07-20 | Sprint `1.67` ✅ **Done; Phase `1` reclosed** — generic Kubernetes reachability now depends only on `ToolKubectl` and authoritative `kubectl cluster-info` against the selected substrate kubeconfig; local RKE2 file/install/service facts remain explicit home-local nodes and no longer contaminate AWS or other substrate-neutral prerequisite closures. Evidence: prerequisite registry 8/8, stable `gateway-pods` 1/1, absorbing OOM 1/1, unit 1855/1855, integration CLI 49/49, integration env 49/49, docs lint/check, `git diff --check`, and `prodbox dev check`. Deployment qualification remains pending. |
| 2026-07-19 | Sprint `2.35` 🔄 **Active — derived public-edge certificate `dnsNames` landed** — the keycloak public-edge `Certificate` `dnsNames` is now a projection of the one configured `CertScopeSet`, keyed on each substrate's served host. New `Settings.certScopeSetForServedHost` / `certDnsNamesForServedHost` parameterize the scope set by served host (home served host and AWS subzone each default to exactly their own FQDN); `ChartPlatform.valuesForKeycloak` injects `gateway.certDnsNames` from that projection; and `charts/keycloak/templates/gateway.yaml` renders `dnsNames` as a `range` over it. This is a values-injection projection (not a `const` generated block) because the dnsNames are substrate-dependent — home served host vs. AWS subzone — which a static section cannot capture; the `charts/gateway/` daemon mesh cert is per-node internal and is intentionally NOT derived from the public scopes. Proven behavior-identical for the default (empty `cert_scopes`) by an isolated `helm template` render (`dnsNames: ["test.resolvefintech.com"]`) and correct for a widened set, plus three `settings`-suite tests. **The `edge status` certificate-expiry rungs also landed the same day**: `Prodbox.Host.classifyCertificateExpiry` is a pure fail-closed classifier over the already-fetched cert-manager `Certificate public-edge-tls` document + wall-clock now (absent `notAfter`/`renewalTime` ⇒ `certificate-unobservable`; `notAfter <= now` ⇒ `certificate-expired`, priority; `renewalTime <= now` ⇒ `certificate-renew-due`; else `certificate-current`), with no repo-side renewal-window recompute; the report renders `CERTIFICATE_EXPIRY=<rung>` (7 `host`-suite tests). Evidence: `prodbox dev check` exit 0, unit 1854/1854, integration cli/env 49/49. The ONLY remaining code-owned item is the retention re-key (deliberately deferred for live-safety, behavior-identical for the default); the live serving proof is Sprint `5.22`. |
| 2026-07-18 | Sprint `5.20` ✅ **Done — derived restore graph wired into the live suite** — the `TestRunner.hs` restore cycle now runs through the Sprint-5.20 total executor: `restoreCycleActions` returns one `runDerivedRestoreGraph` action driving `runRestoreGraphWith` over `buildRestoreGraphForPlan`, replacing the fail-fast `runSequentially` fold. Each node dispatches through the unchanged `restoreCycleStepActionWithGatewayStability` (recorder bracketing preserved); `projectRestoreReport` writes the full per-node outcome table and returns the first node failure's exit code, with the whole cycle as one action so the surrounding suite fold still fails fast AFTER a failed restore while the restore INTERNALLY runs to completion. New pure bridges `restoreCycleStepNodeId` / `restoreCyclePlanRequirement` / `buildRestoreGraphForPlan` keep graph derivation and live dispatch on one bijection, proven by a new plan-wiring-bijection block in `RestoreGraphSuite`. Evidence: `prodbox dev check` exit 0, unit 1820/1820. The end-to-end aggregate-report exercise (an independent app-chart restoration surviving a retained-SES failure) is the non-blocking Standard-O `prodbox test all` axis. |
| 2026-07-19 | Sprint `2.35` 🔄 **Active — certificate-scope config field + fail-fast validation landed** — `DomainSection` gains `cert_scopes :: [Text]` (default empty = today's exact served host, so behavior is identical until an operator widens scope); the Dhall schema (`prodbox config schema`) and binary-sibling `prodbox.dhall` regenerated to carry it; the config emitter round-trips it; and `Settings.validateSupportedPublicHost` is replaced by `validateConfiguredCertScope`, which builds the scope set from config (delegated zones anchored on the served host's parent zone plus the AWS subzone) and rejects a wildcard at an undelegated zone and an uncovered served host fail-closed while preserving the `domain.demo_fqdn must not be empty` error. The `mkScopeSet` reduction (a wildcard subsumes its single-label exact children) makes the canonical set minimal so `impliedBy` is a genuine partial order — caught by the antisymmetry property. Evidence: `prodbox dev check` exit 0, unit 1826/1826 (incl. 5 `settings`-suite fail-fast tests), integration cli/env 49/49. Remaining (side-branch, unblocks only the live-only Sprint `5.22`): the public-edge `dnsNames` generated section (`charts/keycloak/templates/gateway.yaml`), the retention re-key, and the `edge status` expiry rungs. |
| 2026-07-18 | Sprint `2.35` 🔄 **Active — certificate-scope algebra landed** — `src/Prodbox/Tls/CertScope.hs` is the pure operator-configurable scope algebra: smart-constructed `Fqdn`/`DelegatedZone`, `CertScope` (`ScopeExact`/`ScopeWildcard`), the canonical `CertScopeSet` (`mkScopeSet` rejecting a wildcard at an undelegated zone), total `covers` with the strict wildcard boundary (single-label children only — never the apex, never a deeper name), the narrower-or-equal partial order `impliedBy` (`*.a.z` NOT `impliedBy` `*.z`), `bindListener` (rejecting an uncovered host), and the derived `certScopeSetDnsNames` / `renderCertScopeSet` projections (one set → dnsNames + retention key). `test/unit/CertScopeSuite.hs` proves the boundary tables plus QuickCheck partial-order laws and coverage-preservation (100 cases each). Evidence: `prodbox dev check` exit 0, unit 1820/1820. The Tier-0 scope-set config field, the two chart generated-`dnsNames` sections, the retention re-key, the `validateSupportedPublicHost` replacement, and the `edge status` expiry rungs remain; the live serving proof is Sprint `5.22`. |
| 2026-07-12 | Sprint `2.34` ✅ **Done — compiled service boundary + readiness projection + chart statics** — (1) `Prodbox.Gateway.Routes` is the closed `GatewayRoute` registry (`Enum`/`Bounded`; `routePattern`/`routeClass`/`routeForPath`; the `kubeletProbeRoute` smart constructor makes a probe on a non-probe route unbuildable), the single source of every gateway daemon path string; the daemon dispatcher is a total `case` over it, and the client, chart probes (`GatewayProbeEndpoint` deleted), and `ObjectStore`/`TargetSecret` wire paths are all `routePattern` projections. (2) `computeReadiness` is the one pure constant-time projection over drain phase, emitter authority, and workers started; the unconditional serve-start `Ready` write is deleted, the rollback topology sets its monotone authority latch only with validated `StartupRecovery`, the lifecycle-restore gate has a `/readyz` precheck, and readiness `failureThreshold` is 6. Sprint `2.32` subsequently completed the target topology's non-monotone current journal/Lease/recovery witness; no environment-variable hook bypasses readiness. (3) `GatewayChartStatics` is the one source for ports, NodePort, ServiceAccount, and Vault role. Historical closure evidence remains warning-clean build, unit 1610/1610, daemon lifecycle 13/13, CLI/env 49/49, and `prodbox dev check`; current composed deployment qualification is pending. |
| 2026-07-12 | Sprint `1.66` ✅ **Done — native SigV4 object-store client landed; Phase-1 Foundation Epoch complete** — `Prodbox.Aws.SigV4` is the pure, byte-exact SigV4 algorithm (canonical request, string-to-sign, HMAC signing-key chain, authorization header), verified against published AWS vectors (empty-payload SHA-256, the AWS-documented signing-key derivation, and the get-vanilla canonical request/signature). `Prodbox.Minio.ObjectStoreNative` performs every Model-B object-store operation (get/put/conditional-put/list/head/create/delete) as an in-memory, SigV4-signed S3 request over the Sprint-`1.64` shared TLS manager — no `aws` CLI subprocess and no per-operation temp-file bodies (the third `LCPC-2026-07-11` gateway CPU driver). ETag `If-Match`/`If-None-Match` conditional semantics and the absence/conflict outcome taxonomy are preserved. Shared types were extracted to `Prodbox.Minio.ObjectStoreTypes`; the `ObjectStoreBackend` selector in `Prodbox.Minio.ObjectStore` keeps the subprocess path the default config-selectable rollback until live-MinIO parity (a Standard-O axis) is proven, then it is retired. Evidence: warning-clean `-Werror` build, unit green (new `SigV4` + `ObjectStoreNative` conformance suites), `prodbox dev check` exit 0. This completes the four Phase-1 Foundation Epoch sprints (`1.63`–`1.66`). |
| 2026-07-12 | Sprint `1.65` ✅ **Done — measured-capacity certification landed** — `Prodbox.Capacity.MeasuredProfile` is the committed-profile type + pure certification rules (authored CPU below measured `cpu_p99_milli` × 4/3, memory high-water × 4/3 above the authored limit, `throttled_periods_ppm` above 20000 under a CPU cap, or staleness by `hot_path_digest`/30-day age — all one-sided so a measured improvement never fails), field-for-field matching [resource_scaling_doctrine.md § 2F](../documents/engineering/resource_scaling_doctrine.md). `checkMeasuredCapacityProfiles` runs in `runConformanceTier` and is inert until Sprint `5.21` commits the first profile under `dhall/capacity/measured/`. The interim authored gateway envelope rises 250m → 750m (`request == limit`, Guaranteed QoS); to fit the single-node 6500m allocatable the gateway namespace quota rises to 2750m and the over-provisioned vscode ceiling drops to 1400m (pods still draw 800m — operator-approved). `prodbox-config-types.dhall` regenerated. Evidence: warning-clean `-Werror` build, unit 1566/1566 (incl. the new `MeasuredProfile` conformance suite), `prodbox dev check` exit 0. The recorder + first committed profile are the Sprint `5.21` axis. |
| 2026-07-12 | Sprint `1.64` ✅ **Done — shared TLS manager + cached Vault session landed** — two of counterexample `LCPC-2026-07-11`'s three gateway hot-path CPU drivers are removed: `Prodbox.Http.Client` now holds one process-wide `sharedTlsManager` (the per-call `newManager` is deleted), and `Prodbox.Vault.Session` serves the gateway daemon's own service-account token from a cached renewable session (monotonic expiry, single-flight renewal at two-thirds of the lease, sealed/forbidden/unavailable classification, and one `403` invalidate-and-relogin via `withSessionToken`, wired at the target-secret read). `resolveGatewayVaultTokenFor` consults the session; the escape registry's `per-request-vault-login` seam is retired and the per-call-TLS-manager + gateway-service-account-login ledger rows moved to Completed. The operator-secret operator-JWT exchange is inherently per-request and reclassified under Sprint `2.33`/`4.50`; the third driver (`aws` CLI object-store subprocess) is Sprint `1.66`. Evidence: warning-clean `-Werror` build, unit 1552/1552 (incl. the new `VaultSession` conformance suite with a deterministic single-flight test), `prodbox dev check` exit 0. The measured CPU reduction is the non-blocking Sprint `5.21` axis. |
| 2026-07-12 | Sprint `1.63` ✅ **Done — conformance tier + legacy escape registry landed** — `src/Prodbox/Legacy/EscapeRegistry.hs` is the compiled SSoT for the eight pre-cutover escape seams (gateway-hosted authority routes; shared operational AWS credential; host-direct object-store, Vault-KV, and Vault-root-token seams; the `aws` CLI object-store subprocess; and the two per-request gateway Vault logins), each bijectively bound to a `LEGACY-ESCAPE[…]` source marker. `runConformanceTier` in `CheckCode.hs` runs the registry↔source bijection in the fast pre-build phase of `prodbox dev check`, so an unregistered escape or a stale registry entry fails in seconds (the Standard P interim escape-path guard). Evidence: warning-clean `-Werror` build, unit 1541/1541 (incl. the new `EscapeRegistry` conformance suite), `prodbox dev check` exit 0. First Foundation Epoch implementation sprint; the epoch's `1.64`–`1.66`/`2.34`/`4.51`/`5.20`/`5.21`/`7.34` remain the active front. |
| 2026-07-12 | Sprint `0.17` ✅ **Done; Foundation Epoch adopted, Phase 0 reclosed** — the four `LCPC-2026-07-11` failure mechanisms receive structural owners: Sprint `2.34` (compiled service boundary and latched readiness), Sprints `4.51`/`5.20` (durability-indexed retained custody and the derived total restore graph), Sprints `1.64`/`1.65`/`1.66` (gateway hot-path session/native-client elimination and measured capacity certification), and Sprint `7.34` (per-run postflight residue narrowing). Standard P gains the interim escape-path guard, whose registry is owned by Sprint `1.63`; Sprints `1.61`/`1.62` are shrink-rescoped with titles and anchors unchanged. The epoch executes before Sprints `1.61`/`1.62` as an execution-priority decision and introduces no `Blocked by` edge onto the `1.61` → `8.12` chain; the Deployment Qualification rows remain pending. |
| 2026-07-12 | Sprint `0.18` ✅ **Done; certificate-scope policy adopted (governance surface)** — an operator-configurable certificate-scope policy makes an unmanaged or uncovered served hostname unrepresentable on the prodbox-managed side; the orphan dashboard-cert incident is dispositioned (serve `/vscode` on the shared host, operator revokes the orphan and unsubscribes — a manual ZeroSSL-console action); parent→child certificate-material handoff is rejected in favor of delivered `AcmeEabMaterial` self-issuance; implementation Sprints `2.35`/`5.22` are registered; and the root `ZEROSSL_POLICY.md` is retired into governed docs. Phase `0` gains an additional governance sprint on the Sprint `0.17` documentation surface (no further reclose event); the Deployment Qualification rows are unchanged. |
| 2026-07-11 | Sprint `0.16` ✅ **Done; Phases 1–8 reopened on expanded owned surfaces** — two current full-suite attempts disproved the nominal deep-readiness, gateway service-capacity, retained-authority isolation, endpoint-binding, and finally-restored-suite claims. The authoritative target now separates Bootstrap Broker, Lifecycle Authority, Target Secret Agent, and Gateway Runtime; capability operations are type-indexed and share observation/admission/execution identity; lifecycle work is durable and resumable; cleanup is an always-run DAG. Standard P makes deployment qualification revision-specific and prevents historical or point-probe evidence from authorizing a seamless/current-architecture claim. Implementation is scheduled in Sprints `1.61`–`8.12`; operational legacy rows remain Pending Removal until single-writer cutover and current-revision qualification. |
| 2026-07-11 | Sprint `8.10` ✅ **Done; Phase 8 reclosed** — `Prodbox.Ses.Readiness` classifies the exact configured sender identity, DKIM signing state, inbound MX, active/enabled receipt rule and S3 action, and Pulumi-owned capture canary list/get capability as `Ready`, retryable `Pending`, terminal `Failed`, or `Unobservable`. The registered `aws-ses` transaction runs provider reconciliation before the bounded semantic poll and cannot reach SMTP mutation after timeout or terminal evidence; `prodbox host check-ses-readiness` exposes the same read-only prerequisite surface. Evidence: warning-clean build, Fourmolu check, focused readiness 23/23, SES transaction 8/8, lease-role 9/9, built-frontend SES fixtures 2/2, full unit 1535/1535, and CLI/env integration 49/49 each. Fresh AWS identity/DKIM/MX/rule propagation and deployed home/AWS invite aggregates remain a non-blocking Standard-O `Live-proof: pending` axis. |
| 2026-07-10 | Sprint `5.17` ✅ **Done; Phase 5 reclosed** — `ValidationKeycloakInvite` alone derives one opaque nested retained-SES preparation plan. Its typed selected-target gateway object-store precondition precedes the exact acquire/reconcile/bounded provider-presence await/target-sync/release trace, interpreted through one call to Sprint `4.47`'s registered ensure. Home and AWS project only their selected sink; non-invite and postflight plans contain no SES mutation. Explicit authority/target coordinates, scoped EKS transport, real different-sink predecessor recovery, read-only deferred prerequisites, and retained cleanup are pinned by focused plan/recovery 10/10, target API 6/6, global target-commit 12/12, full unit 1508/1508, CLI/env integration 47/47 each, and `dev check` 0. Clean-state deployed invite runs remain a non-blocking Standard-O axis; semantic SES readiness was still assigned to Sprint `8.10` at this checkpoint and closed on 2026-07-11. |
| 2026-07-10 | Sprint `5.16` ✅ **Done** — `gateway-pods` now feeds typed pod/status, termination, Event, and metrics JSON into one concurrency-safe recorder through a structured continuous observer. Restart/OOM/failure-high-water and unobservable evidence fail closed across UID replacement and the compiled Phase-1.6/lifecycle/postflight/volume-rebind boundaries; only the separate three-sample healthy window resets for a planned gateway rollout. AWS observation starts at the gateway bootstrap handoff, uses a monitor-private explicit environment, and refreshes its kubeconfig through a request/acknowledgement barrier after EKS recreation. Every Kubernetes read has API and process deadlines. Thresholds derive from Sprint `1.60`'s runtime-memory plan, and logs remain diagnostic-only. Evidence: focused tables 17/17, installed-binary fake-Kubernetes proofs 2/2, warning-clean build, unit 1494/1494, CLI integration 47/47, and `dev check` 0. The longer deployed soak is a non-blocking Standard-O axis. |
| 2026-07-10 | Sprint `4.47` ✅ **Done; Phase 4 reclosed** — separate flat AWS-presence/checkpoint observations feed the total `DesiredPresence` loop and registered `LongLived` `aws-ses` ensure. The supported reconcile now acquires the retained authority lease, recovers released/expired predecessor provider and target effects, mints only fixed-role STS sessions bounded by the grant, writes checkpoints through fresh fenced CAS, repairs the finite SMTP IAM-key inventory, and materializes through the global target-intent protocol. The exact same-account role is registered as an `Operational` resource and teardown re-observes its absence before clearing the trusted user. This row preserves pre-cutover evidence: its Pulumi-owned SMTP principal/policy boundary is explicitly superseded by Sprint `8.11`'s frozen single-writer migration to a Credential-Provisioner-owned `LongLived` identity and retained-home custody. Evidence: warning-clean build, focused lifecycle tables 78/78 plus role tables 9/9, full unit 1476/1476, and `dev check` 0. Live AWS exercise remains a non-blocking Standard-O axis. |
| 2026-07-10 | Sprint `3.25` ✅ **Done; Phase 3 reclosed** — `GatewayProbeEndpoint` makes the lifecycle paths a closed typed choice (`/healthz` liveness, `/readyz` readiness), `GatewayProbeSpec` owns every timing/threshold value, `ChartPlatform` emits the same value used by the generated `gateway-probes.values` defaults, and the Deployment consumes the complete values-backed shape. `prodbox dev lint chart` rejects `/v1/state` in either lifecycle probe. Evidence: warning-clean build, unit 1386/1386, focused probe suite 4/4, chart/Haskell lint and generated drift checks 0, `dev check` 0, independent liveness/readiness negative fixtures, and Helm rendering of three Deployments with six dedicated paths and zero `/v1/state` probes. Runtime stability subsequently landed in Sprint `5.16`. |
| 2026-07-10 | Sprint `2.31` ✅ **Done; Phase 2 reclosed** — the gateway now retains bounded keyed semantic state, signed per-emitter cursor/delta/checkpoint-repair frames, exact staged Model-B continuity, validated Orders, process-wide frame permits, capacity-one child scheduling, and credential/claim/continuity-gated DNS effects. The append-log/full-log compatibility path is removed. Evidence: unit 1382/1382, daemon lifecycle 13/13, CLI/env integration 45/45, the native partition validation, `dev check` 0, a local profiled request burst with 570,320-byte peak live heap under the generated 268,435,456-byte RTS ceiling, and exhaustive TLC exploration of 606,637,449 generated / 51,491,308 distinct states to depth 44 with nine invariants and no violation. The deployed restart-free stability soak remains the non-blocking Standard-O axis owned by Sprint `5.16`. |
| 2026-07-10 | Sprint `1.60` ✅ **Done; Phase 1 reclosed** — `RuntimeMemoryPlan` proves positive nested heap/container budgets, derives the cgroup limit from the matching workload `ResourceEnvelope`, validates finite child concurrency/peak/deadline evidence, exposes typed scratch/high-water projections, and generates the gateway `+RTS -M268435456 -RTS` argv through ChartPlatform. Cabal enables only `-rtsopts`; no heap cap is authored in Cabal, Docker, or Helm. Evidence: config generation/validation 0, unit 1299/1299, CLI/env integration 45/45, `dev check` 0. Sprint `2.31` subsequently consumed the plan and Sprint `5.16` consumed its high-water projection. |
| 2026-07-10 | **Gateway-memory and retained-SES refactor reopened Phases 1/2/3/4/5/8** — live evidence showed repeated cgroup-local gateway OOM kills hidden by Deployment-only readiness, and source audit showed invite-capable suite preparation syncs from but never ensures the long-lived `aws-ses` stack. Planned ownership: `1.60`, `2.31`, `3.25`, `4.47`, `5.16`, `5.17`, `8.10`. Existing completed work remains preserved; the new [legacy ledger](legacy-tracking-for-deletion.md#pending-removal) rows own removal of the superseded unbounded/exit-code-only/manual-precondition paths. |
| 2026-07-10 | Sprint `7.32` ✅ **Done; Phase 7 reclosed** — `AwsSubstratePlatform` compiles the configured component DAG through the shared anchored-order engine before stack-output reads or platform mutation, with total AWS step anchors, final substrate-owned readiness barriers, an explicit AWS-inapplicable MetalLB mapping, and a separate ACME/admin-route tail. A positively established gateway Service port-forward remains alive across daemon-mediated Vault bootstrap and post-Vault full-mode convergence. The EKS mirror classifier delegates to the shared transient base and its last lint allowance is removed. AWS TestRunner bootstrap projects Gateway → SMTP → VS Code → API → WebSocket from the shared restore builder after all three stack reconciles. Evidence: unit 1286/1286; `dev check` exit 0. Live `test all --substrate aws` remains a non-blocking Standard-O proof. |
| 2026-07-10 | Sprint `5.15` ✅ **Done; Phase 5 reclosed** — new `Prodbox.TestRestore` owns one pure, substrate-aware `RestoreCyclePlan`; `supportedRuntimeBootstrapActions` and `supportedRuntimePostflightActions` both interpret it and differ only by the typed optional SMTP step. Before SMTP sync, `gatewayDaemonLivenessPrecondition` adapts the caller-supplied one-shot gateway object-store observation to `BackendRoundTripTarget ComponentGatewayDaemonFull ComponentMinio`, polls it within the shared bounded policy, and returns a loopback-endpoint-naming `StructuredError` without starting SMTP when pending or unreachable. Code-local evidence: unit 1280/1280; CLI integration 44/44; `dev check` exit 0. The home restore-cycle live proof remains non-blocking. |
| 2026-07-10 | Sprint `4.46` ✅ **Done; Phase 4 reclosed** — `isRetryableRoute53CredentialFailure`, `isRetryableHelmFailure`, and `isRetryableHarborPublicationFailure` now delegate to `isRetryableTransientFailure` while retaining only their path-specific extensions. Helm inherits the shared DNS/transport cases, and all three transitional RKE2 entries were removed; Sprint `7.32` subsequently removed the final EKS allowance. Code-local evidence: unit 1276/1276; `dev check` exit 0. |
| 2026-07-10 | Sprint `4.45` ✅ **Done; Phase 4 remains open only for `4.46`** — the validated component DAG now compiles the home RKE2 plan as `concatMap stepsForComponent (componentReconcileOrder dag)` plus an explicit edge tail. The builder validates dependency/phase order and carries the validated DAG/order in `NativeInstallPayload`, all step anchors and phase matches are total, MetalLB/Envoy Gateway/Percona are first-class steps, corrected graph dependencies match production consumption, and readiness targets poll caller-injected one-shot observations within bounds and enforce each component's final barrier before dependants. The plan-golden changes are intentional (three visible platform steps; redundant home MinIO steady-state step removed). Evidence: config schema regeneration and validation exit 0, unit 1273/1273, real `cluster reconcile --dry-run` exit 0, `dev check` 0. |
| 2026-07-10 | Sprint `4.44` ✅ **Done** — `RegistryStorageBackend` holds the registry S3 configuration and requires an explicit `RedirectPolicy`; the canonical MinIO-backed record uses `RedirectDisabled`. `registryConfigYaml` remains an `unlines` renderer but consumes the typed record. The golden output is preserved and resource ownership is unchanged (registry-config golden, unit 1268/1268, `dev check` 0). Sprint `4.45` closes in the row above; Phase 4 is now open only for `4.46`. |
| 2026-07-10 | Sprint `3.24` ✅ **Done; Phase 3 reclosed** — the exhaustive `operatorAvailableTarget` registry binds the graph-projected Percona gate to a one-shot `Available=True` observation through `ReadinessObservation`; pending and unreachable observations fail closed. New `ComponentId` constructors require an explicit compile-time registry decision, while an existing config-driven ID with no target fails closed at runtime (unit 1266/1266, chart lint 0, `dev check` 0). |
| 2026-07-10 | Sprint `2.30` ✅ **Done; Phase 2 reclosed** — `Prodbox.Vault.RoleId` supplies `VaultRoleGatewayDaemon` to both the supported `ChartPlatform`-generated gateway `vault.role` and `defaultVaultReconcilePlan`; the shared name is `prodbox-gateway-daemon`, bound to exactly `prodbox-gateway` + `gateway-gateway`. The closure does not claim static chart defaults or other gateway configuration surfaces (unit 1260/1260, `dev check` 0). |
| 2026-07-10 | Sprint `1.59` ✅ **Done; Phase 1 reclosed** — `ReadinessObservation`, `ReadinessProbeResult`, and typed `ComponentReadinessTarget` values carry caller-injected one-shot actions; dispatch is exhaustive, target/probe mismatch refuses before polling, and pending/unreachable observations remain bounded and fail closed. The graph records `ProbeServiceActive` for cluster base, daemon-mediated Vault-unseal ordering, and gateway-full's `BackendWriteEdge` to MinIO (`config generate`/`config validate` exit 0, unit 1259/1259, `dev check` 0). Its production bindings subsequently landed in `3.24`/`4.45`/`5.15`/`7.32`. |
| 2026-07-10 | Sprint `1.58` ✅ **Done** — split `ComponentVaultWorkload`/`ComponentVaultUnsealed` (`ProbeRolloutComplete`/`ProbeVaultUnsealed`) and `ComponentGatewayDaemonPreVault`/`ComponentGatewayDaemonFull` (`ProbeRolloutComplete`/`ProbeBackendRoundTrip ComponentMinio`); `EffectDAG.acyclicTopologicalOrder` now accepts a caller tie-break and `ComponentGraph` supplies `fromEnum`; the git-ignored schema was regenerated (`config generate`/`config validate` exit 0, unit 1250/1250, `dev check` 0). Its derived-order consumer subsequently landed in Sprint `4.45`. |
| 2026-07-10 | Sprint `1.57` ✅ **Done** — `TransientFailureClass` + `isRetryableTransientFailure` form the shared constructor-owned retry base in `Prodbox.Service`, the Phase-1 AWS-validation caller delegates to it, and `CheckCode` rejects new standalone inline retry tables (unit 1248/1248, `prodbox dev check` 0). Phase `1` remains reopened for `1.58`/`1.59`; downstream RKE2/EKS delegation remains `4.46`/`7.32`. |
| 2026-07-10 | **Bootstrap-readiness refactor reopened** Phases 1/2/3/4/5/7 to complete graph-derived reconcile ordering, total readiness observation, the retry-classifier SSoT, typed registry/Vault-role records, and restore-cycle DRY — Sprints `1.57`/`1.58`/`1.59`/`2.30`/`3.24`/`4.44`/`4.45`/`4.46`/`5.15`/`7.32` (Standard A/N own-surface reopen). Sprint `4.45` subsequently closed the identified home-RKE2 order-projection gap ([Standard C](development_plan_standards.md#c-honest-completion-tracking)). |
| 2026-07-06 | Bootstrap readiness-race **foundation** landed — Sprints `1.56` (typed component dependency/readiness graph + `EffectDAG` lowering), `3.23` (graph-sourced chart edges, Percona `Available` gate), `4.43` (single `ReconcileStepId` narration table + deep registry→MinIO edge gate + Harbor retry-classifier fix), `7.31` (same deep gate on the AWS substrate). The graph/deep-gate foundation is real; full order-derivation, total readiness observation, and the config SSoTs remain scheduled (reopened 2026-07-10 above). |
| 2026-07-05 | Daemon-mediated post-bootstrap control-plane boundary — Sprints `2.29` (pre-Vault daemon loader + `POST /v1/bootstrap/vault/ensure`), `4.42` (root Vault lifecycle via the daemon, no host fallback), `5.14` (`daemon-bootstrap` validation), `7.30` (per-run Pulumi object-store via the daemon API). Phases 2/4/5/7 reclosed. |
| 2026-07-04 | Explicit resource guardrails — Sprints `1.55` (`capacity.resource_plan` schema), `3.22` (chart resource envelopes + namespace quotas), `4.41` (RKE2/kubelet reservation + systemd drop-in), `5.13` (`resource-guardrails` validation). Phases 1/3/4/5 reclosed. |
| 2026-07-03 | Pulsar broker transport + topic lifecycle (`3.21`/`4.35`), fail-closed spot-price gate (`7.27`), EKS VPC ownership hardening (`7.29`), static retained EBS PVs on EKS (`7.28`), `eks-volume-rebind` validation (`5.12`). |
| 2026-07-02 | Gateway/Orders + durable-event CBOR migration (`2.27`/`2.28`), substrate-typed placement + host-provider frame + test-EBS reaper (`4.37`/`4.38`/`4.40`), tiered-storage capacity + AWS quota preflight (`4.36`), test-topology command surface + `.test-data` isolation (`5.11`). |
| 2026-06-26 | **Historical home-substrate aggregate `prodbox test all` GREEN** — 18/18 named validations + both cabal suites; the provider destroy and contemporaneous residue check reported success for EKS. This is command/provider/residue-check evidence for the then-current topology, not independent exact absence proof and not current-revision qualification across Phases 1–8. |
| 2026-06-16 | Vault-root + cluster-federation foundations closed on their code-owned surfaces — Sprints `1.35`–`1.38`, `2.26`, `3.19`/`3.20`, `4.29`–`4.33`. The master-seed HMAC derivation machinery is **removed** from the supported path (Sprint `3.19`). |
| 2026-06-15 | MinIO/Pulumi encryption finalized to **Model B** — prodbox object-level Vault-Transit envelope with whole-system zero-child-info framing (one generically-named bucket of opaque `objects/<hmac>.enc`, `prodbox-envelope-v2` hashed AAD, decrypt-to-scratch Pulumi interposition, Pulumi's own secrets provider dropped). Refines, does not reverse, the 2026-06-14 model; reopens no new phase. |
| 2026-06-14 | Secrets model **finalized to Vault-root + cluster federation** — Vault is the sole secrets/KMS/PKI root, a sealed Vault bricks the cluster (fail-closed), the master-seed HMAC derivation model is **retired** (not extended), and `FileSecret`/Secret-mounted plaintext Dhall is **removed**. Sprint `0.13` deleted `VAULT_REFACTOR.md` and added [cluster_federation_doctrine.md](../documents/engineering/cluster_federation_doctrine.md). |
| 2026-06-11 | Vault refactor Sprint `0.12` closed — [vault_doctrine.md](../documents/engineering/vault_doctrine.md) SSoT + documentation harmony. |
| 2026-06-09 | Design-intention review reopen — Sprints `0.9`/`0.10`, `1.29`–`1.32`, `2.24`/`2.25`, `3.15`/`3.16`, `4.26`/`4.27`, `5.6`, `7.12`/`7.13`; all landed. |
| 2026-06-07 | Single ZeroSSL ACME issuer (`zerossl-dns01`) + S3 cert retain-and-restore finalized — Sprints `7.11`/`4.24`/`8.7`. The earlier two-issuer/`IssuerClass` staging+production model was reverted to one ZeroSSL issuer. |
| 2026-06-05..09 | Live AWS-substrate parity proven for the then-canonical slice — Sprints `7.5`, `8.5`/`8.6`/`8.8` (NLB-target Route 53, delegated-subzone cleanup, per-run postflight teardown, OIDC redirect, `keycloak-invite` capture/link-follow on `aws.test.resolvefintech.com`, destructive lifecycle, `prodbox nuke` proof). |

## Document Index

| Document | Purpose |
|----------|---------|
| [development_plan_standards.md](development_plan_standards.md) | Conventions for maintaining the development plan |
| [system-components.md](system-components.md) | Authoritative target component inventory for the Haskell rewrite |
| [substrates.md](substrates.md) | Authoritative inventory of substrates the canonical test suite runs against |
| [00-overview.md](00-overview.md) | Target architecture, current baseline, and hard constraints |
| [phase-0-planning-documentation.md](phase-0-planning-documentation.md) | Phase 0: Planning and documentation topology for the rewrite |
| [phase-1-runtime-cli-aws-foundations.md](phase-1-runtime-cli-aws-foundations.md) | Phase 1: Haskell runtime, CLI, config, and Pulumi foundations |
| [phase-2-gateway-dns.md](phase-2-gateway-dns.md) | Phase 2: Haskell gateway runtime and DNS ownership |
| [phase-3-chart-platform-vscode.md](phase-3-chart-platform-vscode.md) | Phase 3: Haskell chart platform and public workload delivery |
| [phase-4-lifecycle-canonical-paths.md](phase-4-lifecycle-canonical-paths.md) | Phase 4: Lifecycle hardening, Pulumi decoupling, and Python removal |
| [phase-5-canonical-test-suite.md](phase-5-canonical-test-suite.md) | Phase 5: Canonical test suite — substrate-agnostic named validations |
| [phase-6-clean-room-handoff.md](phase-6-clean-room-handoff.md) | Phase 6: Final clean-room rerun and zero-Python handoff |
| [phase-7-aws-substrate-foundations.md](phase-7-aws-substrate-foundations.md) | Phase 7: AWS substrate foundations — onboarding, IAM, quota, and AWS substrate parity with the canonical suite |
| [phase-8-email-invite-auth.md](phase-8-email-invite-auth.md) | Phase 8: Operator-invited email authentication via Keycloak + AWS SES |
| [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md) | Comprehensive ledger of cleanup/removal history and ownership |

## Sprint Status

### Status Vocabulary

| Status | Meaning | Emoji |
|--------|---------|-------|
| **Done** | Deliverables implemented for the sprint-owned surface, validated on the code-owned surface, and aligned in docs (a pending live-infra proof does not prevent `Done` — [Standard O](development_plan_standards.md#o-code-local-completion-vs-live-infra-proof)) | ✅ |
| **Active** | Work has started and remaining implementation or documentation work is explicitly listed | 🔄 |
| **Blocked** | Closure depends on an unmet **earlier-or-same-phase** sprint or **external** prerequisite — never a later phase and never a pending live-infra proof ([Standards N/O](development_plan_standards.md#n-phase-independence-no-backward-blocking)) | ⏸️ |
| **Planned** | Ready to start once execution reaches the sprint in sequence | 📋 |
| **Live-proof pending** | Code-owned surface `Done` and locally validated; a live-infra proof (live AWS / deployed cluster / unsealed Vault / operator credential) is outstanding. **Non-blocking** ([Standard O](development_plan_standards.md#o-code-local-completion-vs-live-infra-proof)) | 🧪 |

### Definition of Done

A sprint can move to `Done` only when all of the following are true:

1. Its deliverables are implemented in the worktree.
2. Its validation commands pass on the **code-owned surface** through the canonical `prodbox`
   surface (`prodbox dev check`, `prodbox test unit`, `prodbox test integration cli` / `env`).
3. The docs listed in `Docs to update` are aligned with the implemented behavior.
4. Sprint-owned cleanup is reflected in
   [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md).
5. No sprint-owned blocker or remaining work survives.

Per [Standard O](development_plan_standards.md#o-code-local-completion-vs-live-infra-proof), a
proof that requires live infrastructure (live AWS spend, a deployed cluster, an unsealed Vault, an
operator-supplied credential) does **not** prevent `Done`; it is tracked as a distinct, non-blocking
`🧪 Live-proof: pending` note on the sprint. Per
[Standard N](development_plan_standards.md#n-phase-independence-no-backward-blocking), a `Blocked by`
entry may name only an earlier-or-same-phase sprint or an external prerequisite — never a later phase
or a higher-numbered sprint — and an incomplete later phase never reopens or blocks an earlier phase.

## Historical Phase Record

The compact table below records the superseded 2026-08-16 paused checkpoint. It and the longer
dated table are retained for audit history; neither is a current-status ledger. Use
[Resume Here](#resume-here) for the only current execution order and posture.

| Phase | Current status | Teardown-correction owner |
|-------|----------------|---------------------------|
| 0 | ✅ Closed | Existing MISU/Pure-FP governance is sufficient; no new general doctrine primitive |
| 1 | ✅ Closed | Existing typed capability/config foundations are sufficient |
| 2 | ✅ Closed | No Gateway or Bootstrap Broker runtime change is assigned here |
| 3 | 🔄 Active | `3.41` recovery topology/observation foundation landed; recovery-only render and absent-cluster artifact authority remain |
| 4 | 🔄 Active | `4.84` exact keyed algebra, `4.85` durable kernel, and `4.86` recovery candidate are all partially implemented; their closure dependencies and terminal proof gaps remain |
| 5 | 🔄 Active | `5.35` code-local oracle is green; `5.36` has the descriptor-bound client but not the `TestRunner`/legacy-executor cutover |
| 6 | ⏸️ Blocked | `6.5`, blocked by `4.86` + `5.36`, owns public generic/home sole-writer cutover |
| 7 | 🔄 Active | `7.36` exact adapter foundations landed; Provider session v3, causal create generation, terminal audit, and live proof remain |
| 8 | ✅ Closed | SES specialization is unchanged; qualification remains pending globally |

### Prior phase closure record

**Every code-owned phase surface is closed (2026-08-14).** Sprints `2.48` ✅ and `2.50` ✅ closed;
Sprint `2.51` 🔄 is the single open sprint, registered from `2.50`'s live proof with its cause already
taken. Prior state (2026-08-13): Phase `4` recloses on Sprints `4.78`,
`4.79`, and `4.80` ✅ and Phase `5` on Sprint `5.34` ✅, taking the unowned `Pending Removal` count
to **1**. Phase `3` recloses on Sprint `3.35` ✅ —
the control-plane listen port and the in-cluster role-URL shape each have one compiled owner, and
the module that declined to own the port was wrong about it. Phase `2` recloses on Sprint `2.45` ✅ —
the Bootstrap Broker's durable reads now have validity predicates that can refuse. Phase `1`
recloses on Sprints `1.87` ✅ and `1.88` ✅ — the empty served hostname is now unconstructible rather than refused and
`substratePublicFqdn` is deleted; and `ValidatedSettings` has one production constructor, with the
site that forged one deleted along with two production `error` calls. The reopen was own-surface
(Standard A) and blocked no other phase.

**Previously (2026-08-11, second entry).** Phase `4` recloses on
Sprints `4.76`/`4.77` ✅ — the destructive-path observation folds, the fail-closed tag sweep on both
owning surfaces, the two AWS argv builders, and the now-load-bearing `--yes`. Phase `5` recloses on
Sprints `5.32`/`5.33` ✅ — the three named validations that could not fail. Both reopens were
own-surface (Standard A) and neither blocked the other or any earlier phase. Historical reopens and
reclosures remain recorded in the rows below; forward-only blockers follow Standards A/N, and
clean-room deployment qualification remains a distinct, pending Standards O/P axis.

| Phase | Name | Prior closure record | Historical owner |
|-------|------|----------------------|------------------|
| 0 | Planning and Documentation Topology for Haskell Rewrite | ✅ **Reclosed on Sprint `0.17`** after adopting the Foundation Epoch and the Standard P interim escape-path guard (previously reclosed on Sprint `0.16` for the physical control-plane SSoT and deployment-qualification governance). Governance Sprint `0.18` adds the certificate-scope policy adoption as an additional governance sprint on the same documentation surface (no further reclose event). Governance Sprints `0.19` and `0.20` (2026-08-03) likewise add repository secret hygiene and then repository value hygiene on the same surface, with no further reclose event: every committed value that stands in for real-world data is officially synthetic, unmistakably synthetic, or declared real in place. Governance Sprint `0.21` (2026-08-05) adds governed-document metadata reconciliation on the same surface, again with no reclose event: the `**Status**:` value set and cited-source-path existence become machine gates, and the `**Referenced by**:` field is struck repository-wide as derived data that measured 7% complete and 8% wrong. Governance Sprints `0.23` and `0.24` (2026-08-07) continue on the same surface with no reclose event: `0.23` corrects three false governed-document claims about the Tier-0 config surface against source — the "no human Dhall authoring surface" defense of Ring 1, the "zero version-controlled `.dhall`" inventory, and a `prodbox-config-types.dhall` guard entry that named a registry the file is not in — and states plainly what decoding does and does not validate; `0.24` ✅ **Done (2026-08-07)** lands the Tier-0 drift gate, which cannot reuse the tracked-generated-path registry because that machinery is scoped to version-controlled content and the file is git-ignored, so it reads the binary-sibling path directly and compares the canonical re-render of the decoded record. Its bound is recorded rather than implied, because the first mutation exercise proved it: the gate catches representational drift — including a hand-edited resource plan whose emitted `concurrentDraws` list, the Ring-1 `assert`'s own input, goes stale — and cannot catch a primitive edit that round-trips, which is registered as an unowned Standard-P-touching follow-up rather than absorbed. Governance Sprint `0.26` ✅ **Done (2026-08-10)** continues on the same surface with no reclose event, appending [chaos_hardening_doctrine.md § 24](../documents/engineering/chaos_hardening_doctrine.md) — *an observation has a layer* — after a live failure showed § 23's one-derived-encoder rule is satisfiable by a value that is still wrong: `apiEgress` derives its NetworkPolicy from a live observation of `service/kubernetes` and is wrong in both coordinates, because policy is evaluated post-DNAT against the endpoint. It also corrects in place, per Standard C, the probe/route single-source claim, which reads as a property of every chart while the lint covers seven charts on hand-listed filenames and no gate reads a `networkpolicy.yaml` for content. Governance Sprint `0.25` ✅ **Done (2026-08-08)** continues on the same surface with no reclose event, and corrects the doctrine where it failed rather than where it was missing: closing a § 21 class-D gap (Sprint `1.80`'s closed union) broke twenty integration cases because three of four hand-written Tier-0 encoders were outside the typed region, and the resulting decode failure was converted into an exception and then into a socket closed with zero bytes. `chaos_hardening_doctrine.md` gains **§ 23, "Conversions — where the moves stop"**; § 22 gains a fourth honest consequence; § 21's "Neither needs new doctrine" is corrected in place; and `resource_scaling_doctrine.md` § 2C — the owner of the ring vocabulary — gains **"The region of Ring 2"**, recording that `dev check`'s `cabal build … all` compiles `lib` and `exe:prodbox` and no test suite, so every Ring-2 claim about `test/` was made over a region that excluded it. | Documentation topology, certificate-scope governance, repository value hygiene, governed-document metadata gates, conversion boundaries and gate regions, and Standard P |
| 1 | Haskell Runtime, CLI, Config, and Pulumi Foundations | ✅ **Reclosed 2026-08-13 on Sprint `1.89` (Standard A/N)** — **Sprint `1.89` ✅** gave the Tier-0 coordinates a retained parse, closing the per-field remainder `1.88` split off and with it the ledger's last unowned row. `ValidatedCoordinates` on `ValidatedSettings` is built by `validateConfig` from nine smart-constructed types in the new `Prodbox.Settings.Coordinate`; every rule that already existed is moved character-for-character, **the Dhall wire format is byte-identical**, and so no Standard-P generated-config identity change occurs. **The row described one defect and there are two.** Nine fields were *decided and discarded* — `validateLocalConfig` refused a malformed value and returned `()`, the Provenance class Sprint `1.83` closed for the public edge and no further. Five were **never decided at all**, and two of those are not obscure: `route53.zone_id`, the zone every home DNS write uses, was checked only for emptiness while the structurally identical `aws_substrate.hosted_zone_id` had been shape-checked since Sprint `1.81`; and `pulumi_state_backend.region` had no rule anywhere while both siblings in its three-field section had one, and it is read straight into an S3 client. 35 coordinate reads across 11 modules and 5 served-host reads across 4 now read the projection, and **seven use-site re-decisions are deleted rather than moved** because an `AwsRegion` and a `Route53ZoneId` have no empty inhabitant. `acmeClusterIssuerSpec` takes the parsed account and region, which is Sprint `1.87`'s finding applied where it still held. **Two drafts were refused by the repository itself.** The both-or-neither ACME rule refuses `prodbox config generate`'s own output, because `defaultConfigFile` ships the ZeroSSL directory with an empty contact — the halves are not symmetric. And `checkTier0CoordinateReads`'s first run flagged a *correct* read, because one module bound `config` to both a validated and an unvalidated config; the binding was renamed rather than the rule weakened. **Bounds stated**: shape, not reachability; a compiled rule over a source region, not a property of the type; unvalidated-`ConfigFile` reads deliberately unregistered; the empty-string tolerance surviving at exactly two no-error-channel renderers, both named in Haddock. Two residuals recorded rather than absorbed. Evidence: `dev check` 0, `dev docs check` 0, `dev lint docs` 0, `test unit` 0 at 3430 + 27 + 33 + 27. Prior reclose on Sprints `1.87` and `1.88` (2026-08-13) — **Sprint `1.88` ✅** gave `ValidatedSettings` one production constructor. Its row read as though the exported constructor were a diffuse risk; there were exactly **three** applications tree-wide — `validateConfig`, one production forge, and one test fixture. The forge (`defaultResourceStatusSettings`) built a record no validation had produced so it could call a function reading two of its four fields, and got its plan by `error`-ing; it is **deleted rather than guarded** by narrowing `resourceStatusLines`, taking two production `error` calls with it, and `checkValidatedSettingsMinter` keeps the seam closed — keying on field *assignment*, so a record update is caught by the same rule. **The bound is stated**: a compiled rule over a source region, not a property of the type, because the unit suite builds fixture settings purely at 40 sites and `validateConfig` is `IO`. All three of the row's counts were restatements and all three were wrong (30/40/74 recorded, 27/18/56 measured); the per-field remainder is **re-scoped in place**, with the newly-recorded fact that retyping in Dhall would be a Standard-P generated-config identity change and the non-cascading shape is Sprint `1.83`'s parsed projection. **Sprint `1.87` ✅** — an own-surface reopen closing the re-scoped successor Sprint `1.84` registered against itself, and with it the last Phase-`1` `Pending Removal` row on the public-edge surface. `substratePublicRouteUrl` rendered `https:///path` for a substrate declaring no served host; its row prescribed handing the pure renderer a resolved `String`, which would have left `""` a well-typed inhabitant and the refusal in caller discipline — the property `1.84` already had and recorded as insufficient. The renderers now take the `ValidatedServedHost` that `validateConfig` already builds, whose `Fqdn` is minted only by `mkFqdn`, so the empty rendering is **unconstructible** rather than refused; `substratePublicFqdn` is **deleted** and `requireSubstrateServedHost` is the sole accessor. **The row's premise was wrong and that is the finding**: it called the 16 sites "pure renderers reached from IO callers", true of the renderers and false of the frames calling them — all 16 resolve at **eight** points that already held a `failWith` or a `Left`, and nine functions stopped taking `ValidatedSettings`/`Substrate` entirely because they carried the config only to re-derive a host their caller had resolved. Mutation-proven, and the mutation corrected the sprint in turn: deleting `mkFqdn`'s empty check still refuses an empty name via the `< 2 labels` rule, so the guarantee has two anchors rather than one. The unit case asserts `mkFqdn "" == Left EmptyName` rather than the absence of `https:///` in a rendering, because per `unit_testing_policy.md` statements 10 and 11 the latter is an absence no input could produce. Evidence: `dev check` 0, `test unit` 0 (3399 + 27 + 33 + 27), `test integration cli` 57/57, `env` 0. Prior reclose on Sprints `1.84`, `1.85`, and `1.86` (2026-08-12)** — **Sprint `1.86` ✅** made decode the smart constructor: `MachineId`, `Machine`, and `ClusterTopology` were exported abstractly to force `mkMachineId`/`mkMachine` **and** derived `FromDhall`, so `Dhall.auto` was a second unchecked constructor and the opacity stopped at the decode seam. Six types now carry hand-written instances that read the wire shape through `record`/`field`/`union` and narrow through the constructor owning the invariant. Its row prescribed a `Raw*` DTO; that was measured and declined, because it cascades into `ProdboxParameters` and `ConfigFile` — and the validating decoder is stronger anyway, leaving no window in which the unchecked value exists. `ToDhall` untouched, so every generated `prodbox.dhall` is byte-identical. — **Sprint `1.85` ✅** closed two rows whose shape is a description contradicting what it describes: `certDnsNamesForServedHost`'s Haddock implied a production role Sprint `1.83` had removed (kept and made load-bearing — it now pins the carried cert scope set against its own derivation, the only place that agreement is stated; the row said "the two contract cases" where there are five, three carrying the same comment verbatim three times), and `--yes` on the four stack-destroy verbs still read "Skip confirmation prompts" where Sprint `4.77` had made the flag *be* the confirmation on a command with no prompt (fixed through a named constant both the parser and the typed registry read, leaving the shared `yesSwitchParser` and the three genuinely-prompting `prune-corrupt-checkpoint` verbs untouched). **Sprint `1.84` ✅** — an own-surface reopen (Standard A) closing the residual Sprint `1.83` registered against itself. `substratePublicFqdn` answered `""` where its own projection says "this substrate declares no served host"; all six direct call sites now resolve through `requireSubstratePublicFqdn` and refuse, the two genuinely pure renderers take a resolved host from an IO caller that resolves and refuses, and the accessor is **unexported** so the empty-string answer cannot acquire a new caller. Deletion is deliberately deferred: it would require converting `substratePublicRouteUrl`'s ~10 sites in the same change, the coupled-big-bang shape Sprints `4.74` and `1.83` each declined, and that is now its own re-scoped row with a measured count. The row's estimate was wrong in both directions — "roughly a dozen pure renderers with no error channel" against six direct sites of which four already had one, with the real cascade behind a different function. Prior reclose on Sprint `1.83` (2026-08-09) — an own-surface reopen (Standard A) working this phase's share of the unowned `Pending Removal` backlog; both sprints are Done and Phase `1` has no open sprints. Sprint `1.82` ✅ **Done (2026-08-09)** makes the Tier-0 secret-free guard total and load-bearing: `tier0CarriesNoSecretValues` was exported, documented as the guard that rejects a literal credential, and had **zero production call sites**, so it guarded nothing — the defect class Sprints `1.78` and `4.57` removed. It is now the last step of `decodeProjectConfigDhall`, the one Tier-0 decode gate, and its enumerator is a **positional** pattern over `ProdboxParameters`, so a new section carrying a `SecretRef` is a compile error at the one place that must decide (mutation-proven: *should have 13 arguments, but has been given 12*). The refusal names the dotted fields and never their values. **The overlap the ledger estimated is now measured**: `validateAwsCredentialsRef` runs over the decoded `parameters` inside `validateConfig` and never over this record, so `loadDaemonBinaryContext` and the Sprint `0.24` drift gate both reached a full Tier-0 record with no check at all, and `acme.eab_*` had no local-tier check on any path. Sprint `1.83` ✅ **Done (2026-08-09)** carries the parsed public edge instead of re-deriving it: `validateConfiguredCertScope` built a `CertScopeSet`, bound it to `_`, and returned `()`, and eight production sites rebuilt it from raw `Text`. `ValidatedSettings` now carries `validatedPublicEdge` — the home served host and its scope set plus **`Maybe`** the AWS pair — so the empty-string AWS hostname Sprint `1.81` recorded as its own residual is gone from every caller with an error channel, and `resolveRootPublicFqdn` reduces to the shared accessor. The unit case **compares the carried scope set against the derivation it replaced** on both substrates, so this is a provenance change and not a behaviour change. Two residuals are registered rather than absorbed, one of them correcting an estimate by measurement: narrowing `substratePublicFqdn` to the `Maybe` its projection carries cascades through roughly a dozen pure manifest renderers with no error channel — established by attempting it — so it is a separate call-site sprint (Standard L). Prior reclose on Sprint `1.81` (2026-08-07) — every sprint of the 2026-08-05 own-surface reopen (`1.76`, `1.77`) and of the 2026-08-07 Tier-0 config audit (`1.79`, `1.80`, `1.81`) is Done and validated on its code-owned surface, so the reopen closes. Prior reclose on Sprints `1.72`/`1.73`** (own-surface reopen, Standard A/N). The Ring-1 `assertPlanValid` Dhall over-commit shim is built (`renderProjectConfigDhall` lean-emit; an over-committed `prodbox.dhall` fails to load) and `config generate` derives a host-fitting `host_capacity` from the observed host (fail-fast when too small; `--portable` for host-agnostic generation) via the shared `Capacity.HostProbe` reader. Prior reclose on `1.71`: `Prodbox.Capacity.Derivation` is the sole workload-envelope builder; raw workload envelopes no longer decode. Evidence: `Tier0PlanAssert` 3/3, parser round-trip, live host-fit generate/validate, and `dev check` exit 0. Own-surface reopen on Sprint `1.74` (2026-08-03) declares the served public hostname (`Prodbox.Settings.supportedPublicHostname`) a real value rather than leaving it indistinguishable from the synthetic hostnames beside it (`vault_doctrine.md` §20.1); it recurs in ~260 places and must be real. Own-surface reopen on Sprint `1.75` (2026-08-04) implements the `vault_doctrine.md` §20.5 mechanical outer ring in `dev check`: a tracked file carrying a scanned provider credential shape outside the scanner's own exclusions now fails the gate, scoped to the version-control index so the git-ignored `test-secrets.dhall` stays out of reach. This closes the first of the three `dev check` policies Sprint `0.19` registered and `0.20` recorded as unclosed. **Own-surface reopen 2026-08-05 (Sprint `0.21` topology sweep): 🔄 Active.** Sprint `1.76` ✅ **Done (2026-08-07)** makes readiness evidence provenance-carrying: `RoundTripWitness` was forgeable from a string literal and is now opaque behind a `dev check`-enforced minting allowlist, the deep readiness slot has its own result type so a shallow probe no longer inhabits it, and the witness carries the instant the write landed so the freshness window bounds the proof rather than the question. It also lands the real gateway CAS lane the sprint budgeted for — the store-returned conditional-put version, discarded at every call site, is threaded through to the daemon, which projects it as `last_backend_round_trip`; the gateway deep probe no longer reads a constant-time `/readyz` latch as proof of a backend write. Sprint `1.77` ✅ **Done (2026-08-07)** closes the retry surface: retryability becomes a property of the (operation, error) pair rather than of the error alone — `serviceErrorDisposition` is three-valued and the retrier that repeats an *indeterminate* outcome requires a hidden-constructor idempotence witness, so the unsafe combination does not type-check — and jitter now exists, where before it existed nowhere in the tree and every retrier shared one deterministic schedule. `RetryPolicy` gains a hidden constructor and a validating `mkRetryPolicy`, and a new `dev check` rule fails any production module that reaches the un-jittered schedule or re-exports the constructor, which is Sprint `1.13` item 2 restated as something that can fail. **Phase `1` has no open sprints on this reopen; Sprints `1.79`–`1.81` are ✅ Done on the config surface.** **Sprints `1.79`–`1.81` ✅ Done 2026-08-07**, registered and closed the same day by the Tier-0 config audit, all on this phase's config surface: `1.79` ✅ **Done (2026-08-07)** derives the in-force config payload instead of hand-writing it — the hand-written renderer omitted `components`, so record completion silently substituted the default graph in the canonical in-force config while the Tier-0 file path preserved it; the round-trip assertion meant to protect this could not fail until its fixture stopped using the default graph, and varying it produced three real failures before the fix landed; `1.80` ✅ **Done (2026-08-07)** makes `public_edge_advertisement_mode` a union rather than a two-value enum carried as free `Text` — the one field on this surface where the illegal state was closable in Dhall rather than merely detectable in Haskell, so a misspelling now fails the type check instead of reaching a string comparison; the three comparison sites are gone and the cross-field `bgp ⇒ peers` rule stays in Haskell, where it can be decided; `1.81` ✅ **Done (2026-08-07)** makes `validateLocalConfig` total over the record so an added field cannot be skipped silently — as a **positional** pattern, because the field-named form the sprint proposed turned out not to be a forcing function at all (the mutation exercise objected only at an unrelated construction site). Five sections that had no coverage now have it, the component graph is validated at decode rather than at bring-up, and both `PublicEdge.hs` crashes are gone: one became an AWS-tier decode refusal, the other was deleted along with the zero-caller renderer that needed it. **Phase `1` now has no open sprints on this reopen.** No prior closure on this phase was falsified. Prior reclosures stand. | Operation-indexed capabilities, exact graph requirements, absolute deadlines, service-capacity algebra, derived workload-resource contracts, resource-envelope over-commitment proof and decode gate, the Ring-1 Dhall over-commit shim and host-fitting generation, native object-store and managed Vault-session boundaries, conformance tier and legacy escape registry, measured calibration certification, and substrate-neutral prerequisite topology |
| 2 | Haskell Gateway Runtime and DNS Ownership | ✅ **Stays closed; Sprints `2.48` and `2.50` closed 2026-08-14, and Sprint `2.51` 🔄 opened when `2.50`'s live proof let the bring-up reach a defect nothing had yet seen — a worker Pod image pinned to a **config** digest where a registry can only resolve a **manifest** digest, both being the same sixty-four hex characters and separable by no smart constructor over the text. Registered with its reproduction and its cause both taken, which is the direct dividend of `2.46`–`2.50`: four of the five refusals between the operator and it now name themselves.** Sprint `2.50`'s proof passed on the arm it changed, evidenced by the durable object — the checkpoint stuck since 17:39 at store version 2 / fence generation 7 was rewritten to version 4 / generation 13, which is `driveSecretWorker` rolling a superseded pre-receipt checkpoint and nothing else in the tree writes it. Sprint `2.50` ✅ closes the durable-checkpoint wedge that was the last blocker on the bring-up path, and **both halves of this plan's own description of that object were refuted by decoding it**: it is not Vault-enveloped (the bootstrap store's `StoredEnvelope` is canonical CBOR over a type named `SecretFreeWorkerRequest`, readable with no Vault session on a host whose Vault is uninitialized), and it is **three** compared fields that cannot repeat across invocations rather than two — the operation deadline is `acceptedAt + budget`. The remedy is narrower than any of the three options registered, and the bound that scoped the sprint chose it rather than being argued across: a checkpoint is a *result* record, but that is a statement about checkpoints which **carry** a result, and the stuck one is `InternalNoWorkerReceipt`. So the roll arm widened, bounded three ways — pre-receipt only, a **strictly older** fence generation only, and the predecessor's worker **destroyed** by a UID-preconditioned delete rather than observed absent, which is stronger than Sprint `2.47`'s absence observation because it causes absence instead of inferring it. Exactly one of the seven cases in the pre-existing exhaustive mismatch table changes behaviour, and receipted checkpoints stay refused on every binding. The **fifth** instance of the payload-free-refusal collapse closed with it, and it is the first whose cost is demonstrable rather than argued: the wrong field count above is what a five-site payload-free constructor cost. Sprint `2.48` ✅ closes both items it carried — the 300-second Lease coupling is **declared** rather than removed by renewing, because renewal is *adversarial* to Sprint `2.47` (retirement needs a positively expired Lease, so a renewer outliving a wedged bring-up would restore the permanent wedge `2.47` closed), and the acquisition-path fence leak now compensates through an exact-value CAS back to vacant. That row closed **with its owning sprint** rather than outliving it, which is the orphan shape this plan has caught three times. Evidence: `dev check` 0, `test unit` 0 (**3468** + 27 + 33 + 27), `test integration cli` **57/57**, `test integration env` **57/57**. Prior status — **Sprint `2.47` ✅ Done 2026-08-14.** The ledger's oldest row is closed: a failed bring-up left a durable `bootstrap-session-fence` that no supported command cleared, and `--cascade` preserves `.data/` by design, so the host could never complete `prodbox vault init` again. **The remedy was already in the tree, had zero production callers, and could not be called** — `decideBootstrapFenceRetire` requires three independent facts and refuses closed on ambiguity in each, stricter than all three options the row proposed, with its store half fully wired; what kept it unwired was that the cleanup observation it consumes was bound to a seven-field worker binding and a durable fence carries **three** of those seven. Closed by observing worker absence **by fence generation**, the one identity the fence does carry, with the scope checked in both directions so an answer about another generation is unobservable rather than absence. `acquireFence` now runs acquire → retire → re-acquire, the second pass bounded **structurally** — a separate function with no path back into retirement — rather than by a counter. **What it does not claim is stated at the wiring site**: Pod absence is not Vault-session absence, and it need not be, because every Vault effect re-reads the exact fence immediately before acting, so retiring the fence *is* the revocation and a survivor fails closed at `BootstrapFenceUseFenceStale`. **Seven prescribed remedies were refuted by measurement across the row's life** — two the row's, two the sprint's own, three found while closing it, including one that would have made the fix *worse* (the label it proposed to select on also matches the Broker's own controller Pod) and one where "every construction site including the fakes" was reduced by a single grep to one field, one site, and no fakes. Sprint `2.48` 🔄 takes the second, distinct Lease blocker the row had recorded but never owned; **its first defect was the record itself**, and `2.47` already fixed it — `ensureLease` narrated one fixed string for all six `BootstrapLeaseRefusal` constructors, the exact collapse Sprint `2.46` fixed one level up and this function was missed by, so the next reproduction names the arm instead of describing it. Registering a Planned sprint is not a reopen, so this phase stays ✅. Evidence: `dev check` 0, `test unit` 0 (**3453** + 27 + 33 + 27), `test integration cli` **57/57**. Both sprints carry 🧪 Standard-O live proofs that gate nothing. A Standard-C header correction landed with them: this phase's document still led with the 2026-08-10 reopen while every sprint in it read ✅ and this table had recorded the `2.45` reclose since 2026-08-13 — the precise failure that header was corrected for on 2026-08-08, recurred. Prior reclose — ✅ **2026-08-13 on Sprint `2.45` (Standard A/N)** — an own-surface reopen on the Bootstrap Broker durable-store boundary this phase owns through Sprints `2.33`, `2.36`, and `2.42`. `validValue _ = True` was the validity predicate on every durable read and CAS, so `BootstrapStoreCorrupt` — the store's own refusal constructor — was **unreachable** for the payloads passing through it. **The row was wrong about scope in the direction that matters**: it listed eleven surfaces and called them "nine payload types", but six already had real predicates and it **missed** the seventh undefended one entirely — the durable storage-generation binding every other payload's binding is checked against (measured: 7 types, 20 sites). That correction made the fix one rule rather than seven inventions: these records are read back through `Serialise`, which reconstructs fields positionally and bypasses every smart constructor they are otherwise built through ([chaos_hardening_doctrine.md § 23](../documents/engineering/chaos_hardening_doctrine.md), the seam Sprint `1.86` closed for Dhall), so each predicate re-runs exactly those, plus the Shamir arithmetic `mkInitRecipientCommitment` enforces at the mint site and a non-empty share list on the two share-carrying receipts. The checkpoint predicate sits **beside its type**, which is what lets it stay exported abstractly. The CBOR bypass is reproduced in a unit case rather than assumed; mutation-proven by restoring one accept-anything predicate. **Two bounds stated**: the predicates do not verify a carried digest is the digest *of* its record, and the checkpoint predicate constrains one of nine arms deliberately. **Moves a Standard-P persistence-protocol surface** (both rows already `pending`). Evidence: `dev check` 0, `test unit` 0 (3407 + 27 + 33 + 27). Prior reclose 2026-08-12 on Sprint `2.44` (Standard A/N)** — an own-surface reopen closing the fold defect Sprint `5.33` found and deliberately did not absorb (Standard M keeps runtime and suite-content ownership apart). `gatewayRuntimeSampleExit` mapped both `StableObserved` and `NotStableYet` to a silent `ExitSuccess`, while the gate ten lines above honoured the same constructor by retrying and failing. The row's stated remedy — make it fail — was measured and declined: the function is a sampler invoked at ten points across a suite run, and failing it would abort every run before the gate that owns the verdict was reached. The decision is now a pure total `GatewayRuntimeSampleOutcome`; each arm names what it saw; the not-yet-stable arm states it is not an observation of stability; and a unit case asserts the deliberate sampler/gate disagreement. Prior reclose 2026-08-11 on Sprints `2.42` and `2.43` (Standard A/N) — **Sprint `2.43` ✅ Done (2026-08-11)** closes the three defects Sprint `3.34` uncovered by fixing the NetworkPolicy: the self-observation selector authored `app.kubernetes.io/name=bootstrap-broker` while every chart renders the `prodbox-<component>` form (the only unprefixed occurrence in the repository); `PodWire` required the `apiVersion`/`kind` Kubernetes omits on `PodList` items, so every non-empty list decode failed; and the controller-image check required a `:latest` suffix that `resolveCustomImageTag` overrides on both substrates, so it could never pass. Each was reachable only once its predecessor was fixed. Evidence: the selector is asserted against the chart's rendered label rather than a restated copy, a `PodList` payload shaped as the API returns one is observed, all three substrate tag forms validate against the compiled repository owner, `dev check` 0, `test unit` 0 (3332 + 27 + 33 + 27). Prior: **Sprint `2.42` (Standard A/N)** — the own-surface reopen on the Bootstrap Broker readiness contract this phase already owns through Sprints `2.39` and `2.40` is closed, and Phase `2` has no open sprints. `kubernetesObserveBootstrapLease` discarded its typed transport failure with a wildcard, so a dropped packet, a `403`, and a `404` all reached the operator as `Kubernetes Lease observation unavailable` while `/healthz` answered 200 — [chaos_hardening_doctrine.md § 23](../documents/engineering/chaos_hardening_doctrine.md) corollary 2 at the broker's Kubernetes boundary. **Sprint `2.42` ✅ Done (2026-08-11)**: all six discarding sites in `productionKubernetesWorkerBoundary` compose through `unobservableReason`, and `requestKubernetes` — which collapsed every exception to a bare `"Kubernetes API request failed"`, so fixing the call sites alone would have appended a prefix and no information — now classifies through `kubernetesTransportFailureLabel`. That function matches every `HttpExceptionContent` constructor of `http-client` 0.7.19 plus `InvalidUrlException` onto fixed, payload-free labels with no wildcard arm, so a new upstream constructor is a compile error rather than a silent collapse; the `Request` is matched as `_` and never inspected, because it carries an `Authorization: Bearer` header and a readiness body is operator-visible. Evidence: 25 new cases in `test/unit/BootstrapBrokerProductionBoundary.hs` asserting exact strings, mutual distinctness, the absence of a bare site phrase, and that a planted bearer token reaches no rendered reason; `prodbox dev check` exit 0; `prodbox test unit` exit 0 (3319 + 27 + 33 + 27). A Phase-`3` chart defect caused the outage that exposed this, and `2.42` does not fix that cause — it makes the next such outage name itself. No rendered manifest and no readiness verdict changes. Prior reclose on Sprint `2.41` (2026-08-07) — ✅ **Reclosed on Sprint `2.41` (2026-08-07)** — Sprints `2.39`, `2.40`, and `2.41` are all Done on their code-owned surfaces, so the reopen closes; the live reproducer and the deployed-path readiness change remain 🧪 Standard-O and do not prevent closure. Sprint `2.39` ✅ **Done (2026-08-07)** on its code-owned surface: its third deliverable, the conformance gate, is landed — `checkBrokerReadinessProjection` enforces the constant-time contract structurally (the projection module may import only pure modules, and the request path draws from an exact token allowlist, so a *new* backend call fails the gate, not merely a previously-seen one). Its live reproducer stays 🧪 Standard-O. Sprint `2.40` ✅ **Done (2026-08-07)**: the readiness staleness bound is now *derived* from the observer period and the per-pass budget by a hidden-constructor `ObservationSchedule`, so a bound the observer cannot meet is not constructible. The authored `3 * period` = 15 s was unsound — the observer stamps after a pass, so its inter-stamp interval reaches `period + budget` = 10 s and one missed pass needs 20 s — which meant a broker whose dependencies were all ready projected `Starting` for most of every cycle and was removed by `failureThreshold: 6` after 60 s. Sprint `2.41` ✅ **Done (2026-08-07)**: the emitter's readiness and the runtime that asserts it are now one value, so `Ready` with no runtime — reachable on the *deployed* path, because five sites cleared the continuity runtime and touched readiness on none of them — is unrepresentable; and the monotone `WorkersStatus` flag, written once before any worker existed, is replaced by a heartbeat-bounded `WorkerRoster` with `withSupervisedWorkers` as the only way to run a worker, enforced by a `dev check` rule that raw `withAsync` is not in scope in the daemon. **Phase `2` has no open sprints on this reopen**; its live reproducer and the readiness behaviour change remain 🧪 Standard-O. Prior status (2026-08-04) — a live cold home bring-up surfaced a Phase-2-owned defect blocking every home reconcile: the broker's `/readyz` violates the constant-time contract its own chart comment asserts, performing a MinIO round trip, a Vault call, and two 5-second-deadline Kubernetes reads inline in the probed path. Measured live: `/healthz` 0.19 ms vs `/readyz` **5.003 s** against a 1-second probe budget, so the Deployment never reports available and `cluster reconcile` exits 1 before Vault is initialized. Diagnosed, evidenced, not patched. Prior reclose on Sprint `2.38` (2026-08-04) — own-surface reopen (Standard A) correcting the Sprint `2.36` shutdown postcondition, which demanded an *empty* idempotency map. That is unreachable once any request has completed (completed bindings are retained for replay), so a graceful broker drain wedged permanently — and because the proving transaction never read the phase, a following force-drain could not wake it. The postcondition now asks what it meant to ask: no **running** entry, restoring agreement with the Sprint `5.23` shutdown model. Standard-P lifecycle-orchestration surface; both rows already `pending`. Prior reclose on Sprint `2.37` (2026-07-30) — own-surface reopen (Standard A) making the emitter retained-assertion (unacked-suffix) leak class non-constructible with a failed-checkpoint recompaction liveness fix; byte-compatible, code-owned, `dev check` 0. Prior reclose on Sprint `2.36` (2026-07-27): terminal shutdown is proof-carrying; timeout is explicitly incomplete and cannot publish `BrokerStopped`. | Single-writer emitter actor/journal, non-constructible retained-assertion retention, Bootstrap Broker extraction and proof-carrying shutdown, gateway scope reduction, compiled service boundary and latched readiness, configurable certificate-scope algebra |
| 3 | Haskell Chart Platform and Public Workload Delivery | ✅ **Reclosed 2026-08-15 on Sprint `3.40` (Standard A/N)** — the pre-Vault Broker graph gate observes the requested Deployment revision without demanding availability that Vault lifecycle must create; the changed arm crossed admission live and entered Vault initialization. Prior: ✅ **Reclosed 2026-08-13 on Sprints `3.36` and `3.37` (Standard A/N)** — **Sprints `3.36` ✅ and `3.37` ✅**, both found by the **first live Standard-P qualification run** — the first time this plan has gained work from running the system rather than reading it. `prodbox test all --substrate home-local` failed deterministically, twice, at the cert-manager mirror. **`3.36`**: `mirrorHostArchitectureTarget` passed no platform to `docker pull`/`docker push`, so under the containerd image store it published the whole manifest **index**; for a multi-architecture upstream that index names platforms whose blobs were never fetched. Invisible until now because **every one of the 17 mirror targets that had published before it presents a single platform locally** (the registry carries 24 entries in total). The asymmetry is the finding: the custom-image *build* path beside it has always resolved `supportedHostArchitecture`, and the mirror path — named for it — never consulted it. The sprint **records that it has no successful-publish proof**, because the working mirrors were already in the registry and were skipped. **`3.37`** is a sprint whose entire content is a measurement that exonerates this repository: five hypotheses tested and discarded before a pin moved — stale local content (purged, re-pulled, still fails), multi-arch in general (`alpine:3.20`, identical index shape, fine), quay.io (`v1.16.1` same repo, fine), cert-manager (`v1.16.3/4/5`, `v1.17.1`, all fine), controller-only (all five `v1.16.2` images fail). A specific upstream release is unpublishable and no harness work would have fixed it; the pin moves to `v1.17.1`, which **invalidates any prior component-image identity** since `certManagerChartVersion` is derived from the controller tag. One unowned residual recorded: cert-manager is the only mirrored platform component with **no fallback source**, and `3.37` is the proof that this matters. Prior reclose on Sprint `3.35` (2026-08-13) — an own-surface reopen closing the Haskell half Sprint `3.34` registered and deliberately did not absorb. The control-plane listen port had **no compiled owner** — 14 occurrences across 9 modules, five of them separately-named per-role constants — and the row's own open question (are the five roles *required* to share one port?) is answered by measurement: `runControlPlaneServer` receives the role and binds without consulting it, so a per-role port is not representable and the five constants could never have diverged. The row's count was also low in a way that mattered: it counted the port and missed that the `http://<svc>.<ns>.svc.cluster.local:<port>` URL *shape* was authored at 9 sites. Both now have one owner in the new `Prodbox.ControlPlane.ListenPort`, the `Text` URL projection **derived from** the `String` one. `checkControlPlaneListenPortOwner` fails any `src/` module outside the owner, mutation-proven against the binder — and **named a real restatement on its first run, this sprint's own correction comment**, reworded rather than exempted. `ChartStatics.hs`, which called the port operator-chosen deployment configuration while the binder hardcoded it, is corrected under Standard C. Rendered output is byte-identical. Evidence: `dev check` 0, `test unit` 0 (3410 + 27 + 33 + 27). Prior reclose 2026-08-11 on Sprint `3.34` (Standard A/N)** — **Sprint `3.34` ✅ Done (2026-08-11)**: the Kubernetes API egress coordinate has one compiled owner, `KubernetesApiEgressCoordinate`, observed once from `endpoints/kubernetes` so the post-DNAT address and port arrive together; `apiEgress` renders one `ipBlock` per observed address, and the `bootstrap-broker` and `target-secret-agent` templates bind `.Values.kubernetesApiEgress.*`. The sibling lint `chartTemplatePortLiteralViolations` widens the chart-lint region to every repo-owned template under a closed port-key set, with no allowlist — named ports and `{{ .Values… }}` fall out of the predicate. Its first run named **77** findings, reconciling exactly with the 79 measured on 2026-08-10 less the two the owner had already migrated; all are now bindings. Evidence: `dev check` 0, `test unit` 0 (3325 + 27 + 33 + 27), two-region mutation restored byte-exactly, and both deletion anchors exercised by mutation. Standard-P: this **does** edit a live production rendering path, so the next qualification run must exercise the post-`3.34` rendering. Validation 5 (a broker that reaches ready) stays 🧪 Standard-O pending on Sprint `2.43`, which this sprint does not own. Prior state — 🔄 **Reopened 2026-08-10 on Sprint `3.34` (Standard A/N)** — an own-surface reopen on the chart platform and chart lint this phase owns. A live `prodbox test all --substrate aws` run failed at the `bootstrap-broker` Helm release eight consecutive times: the chart permits Kubernetes API egress on TCP `443`, kube-proxy DNATs the API Service to its endpoint on `6443` before the CNI evaluates egress, and the rule matches nothing. The coordinate has **no compiled owner** — `grep -rn "6443" src/` returns one hit, a kubeconfig string-match — so three sites each author their own, and `apiEgress`, the one place the rule is generated from a live observation, is wrong in **both** coordinates because it observes the Service (pre-DNAT) while policy is evaluated post-DNAT. Sprint `3.34` derives the coordinate from `endpoints/kubernetes` (one observation, both post-DNAT halves) and widens the chart lint's region to every repo-owned template, closing a region gap in which **no gate reads a `networkpolicy.yaml` for content** and 79 numeric port literals across 13 charts sit un-gated. The doctrine it implements is [chaos_hardening_doctrine.md § 24](../documents/engineering/chaos_hardening_doctrine.md) (Sprint `0.26`). **This edits a live production rendering path**, so the next qualification run must exercise the post-`3.34` rendering; both rows were already `pending`. The lint closes drift, not correctness, and is not credited with catching the outage. A **Standard-C correction (2026-08-10)** also landed on the phase header, which still asserted its reclose on Sprint `3.32` and had never recorded `3.33`. Prior reclose — ✅ **Reclosed on Sprint `3.33` (2026-08-09)** — an own-surface reopen (Standard A) closing this phase's one unowned `Pending Removal` row, on the condition that row itself set. Sprint `3.33` ✅ **Done (2026-08-09)** gives `EnsureDnsRecord` the same `DnsOwnerAuthority` `DestroyDnsRecord` has required since `3.32`: an ensure is a mutation against the same coordinate and is the same *Direction* class, and the asymmetry was deliberate scoping rather than a judgement that an ensure is safe. `runEnsure` refuses `DnsProgramOwnerUnauthorized` **before its first observation** — the refusal case asserts an empty boundary call log, so an unauthorized writer never reaches Route 53 rather than reaching it and failing read-back — and the gateway daemon **mints** its authority from `RuntimeRole` × `Substrate` instead of naming an owner beside the coordinate. **Unlike `3.32` this edits a live production write path**, so the no-behaviour-change claim is argued rather than asserted: `DestroyDnsRecord` had zero production construction sites, `EnsureDnsRecord` has exactly one, and the owner it mints is `HomeGatewayDnsOwner` — precisely what `homeDnsProgramInputs` already builds the coordinate with — so the new guard cannot fire on the supported path. The Sprint `3.32` bound is unchanged and not narrowed by this: a ring-2 gate bounds a process, not a protocol, and the two untyped Route 53 writers in `ProviderProduction.hs` remain outside both sprints. Prior reclose on Sprint `3.32` (2026-08-07) — the 2026-08-05 own-surface reopen closes: `3.31` and `3.32` are both Done on their code-owned surfaces and Phase `3` has no open sprints. Sprint `3.32` ✅ **Done (2026-08-07)** makes a typed DNS destroy consume the `DnsOwnerAuthority` the running process holds — opaque, minted only by a total `RuntimeRole × Substrate` table whose range excludes **both** cert-manager owners, so the sprint's named scenario (a home process deleting an AWS cert-manager `_acme-challenge` record by naming that owner on both sides) is unconstructible rather than refused; enforced by a `dev check` boundary in the `RoundTripWitness`/`TargetSinkVersion` idiom and proved by a mutation exercise that reproduced the defect and restored byte-exactly. It changes no live behaviour — `DestroyDnsRecord` has zero production construction sites — and the sprint records that rather than claiming otherwise. Its documentation half **corrected the sprint's own premise a second time**: the Objective said Percona PGO owns the `pguser` password and the sync must run Secret → Vault; source says the reverse (prodbox generates all three Patroni passwords into Vault KV), and the 2026-08-07 correction's replacement claim that "no process copies the value" was also false — exactly one mirror exists, chart-local rather than Haskell, running Vault → Secret with no reverse path. Recorded with citations in `secret_derivation_doctrine.md` § 5.1. Prior status: 🔄 Active (own-surface reopen 2026-08-05) — previously ✅ Reclosed on Sprint `3.30` (2026-08-03)** — own-surface reopen declaring the RFC 6455 WebSocket handshake GUID a real, required constant and pointing the MinIO chart credential default at its actual registration in `vault_doctrine.md` §6.1; comment-only, rendered output byte-identical. Prior reclose on Sprint `3.26` (2026-07-25), which closes the independently validated chart/identity/capacity/graph surface; Phase-4 interpreters and cutovers compose it without backward-blocking Phase 3. Sprint `3.27` derives separate scheduler-request and containment-limit admission axes; Sprints `3.28`/`3.29` remain Done. **Own-surface reopen 2026-08-05 (Sprint `0.21` topology sweep): 🔄 Active.** Sprint `3.31` ✅ **Done (2026-08-07)**: all eight Helm statuses now decode to distinct constructors from `.info.status` (which `--output json` was already requesting and the classifier discarding), an unrecognised status fails closed, and a mutating helper requires a `HelmWritePermit` whose producer refuses a concurrently-held release — so the concurrency error resolves to a typed refusal that cannot be answered by a destroy, where before it deleted the release another writer was mid-install on. Sprint `3.32` remains 🔄 Active with its **scope corrected against source (2026-08-07, Standard C)**: both stated premises are false. There is no `pguser` mirror helper to constrain — every use of the three secret-name helpers is a rendered chart value naming the Secret, so the chart-local materializer reads the operator-owned Secret directly and no process copies the value (Sprint `3.13` removed the mismatch state structurally); the direction rule is satisfied by absence of a mirror, which is stronger than a class with an incomplete instance set. And the DNS owner witness *is* consumed at the delete site — `runDestroy` guards on `ownerMatches` — but it compares two values the same caller supplies, so it proves self-consistency rather than that the running process is the owner. The corrected deliverable is a caller-bound owner witness; it is registered, not landed. Prior reclosures stand. | Separate broker/authority/agent workloads, identities, policies, probes, retained journals, topology-derived resource contracts, one shared resource renderer, single-sourced PVC storage, and derived namespace admission |
| 4 | Lifecycle Hardening, Pulumi Decoupling, and Python Removal | ✅ **Reclosed 2026-08-14 on Sprints `4.81` ✅ and `4.82` ✅ (Standards A/N)** — an own-surface reopen on the residue-observation and destructive-cleanup paths this phase owns, opened by a **doctrine gap rather than a failure**, and closed the same day. [chaos_hardening_doctrine.md § 24](../documents/engineering/chaos_hardening_doctrine.md) (*an observation has a layer*, Sprint `0.26`) requires a derived value to be enforced at the layer its source object is authoritative for; `ResidueStatus` is the common target of **nineteen** producers — reading the Pulumi checkpoint store, AWS resource presence, AWS IAM, AWS EBS, config text, a Pulsar topic, a Vault gate, an object-store listing, SES consumer quiescence, and public-edge TLS — and has no field in which to name one (the layers are enumerated rather than counted; the producer figure is a signature grep, a layer numeral would be a bucketing judgement). [Standard L](development_plan_standards.md#l-cli-doctrine-alignment) makes scheduling it mandatory rather than optional. The defining module already documents two of those layers as "deliberately independent … separate external facts" and then joins them into the same flat type. **`4.81` ✅** made the layer sayable and its minting restricted — a field, **not** a type index, because § 21 names *residue* explicitly in its prohibition on indexing an observed value — with a class-A opaque minter plus a **mutation-proven** `checkResidueObservationMinter` boundary in the `RoundTripWitness`/`TargetSinkVersion` idiom, and it retired `ResidueBackendMinioUnreachable` as the label for authentication failures against a service that was never contacted, and withdrew `residueAbsent` — an exported alias with **no production caller** whose only test asserted it equalled the constructor. **`4.82` ✅** made the cascade consume the layer it actually needs, using the admin credential `runCascadePostflightTagSweep` already loads in the same run; its acceptance criterion is the **inverse** of Sprint `4.76`'s live run — identical host state, exit 0, narration naming AWS — plus a second run proving the refusal arm still refuses. **Both move Standard-P destructive-cleanup surfaces**; both substrate rows stay `pending` and no qualification identity captured before them survives. The consequence they exist to remove has been in this document's own prose since 2026-08-11 with no owner. Prior reclose — ✅ **2026-08-13 on Sprints `4.78`, `4.79`, and `4.80` (Standards A/N)** — the own-surface reopen on the observation-producer and destructive-cleanup surfaces closed, taking this phase's last three unowned `Pending Removal` rows. **Sprint `4.78` ✅** replaced nine prose classifiers (the row said seven) with one anchored, probe-keyed owner copied from `classifyAwsSesPresenceOutput`: bare `404`/`409`/`412` substrings become forms a request id cannot satisfy, four kubectl variants stop matching **stdout**, and three credential arms are **deleted** rather than re-worded. **Its worked example was measured unreachable** — the sole producer of that `Either` is a constant `Left` carrying neither marker word — which is what made deleting arms on a fail-closed teardown gate behaviour-preserving. A test that asserted the defect as an invariant is inverted under Standard C. **Sprint `4.79` ✅** gave two destroy paths opposite remedies for the same shape, decided rather than defaulted: `completeDestroy` **reports** its surviving Pulumi stack entry (the AWS destroy had already succeeded, so refusing would fail a teardown that removed every resource), while the two `head-bucket` arms **refuse**, because an expired credential made `nuke` answer "already gone" about the bucket holding every encrypted checkpoint. **Sprint `4.80` ✅** answered the policy question Sprint `4.76` left open without adding a requirement: the cascade already computes `inferCascadeSubstrate` eight lines earlier and needs no credential to do it, so a missing sweep credential is cannot-confirm exactly when this lifecycle had AWS state in scope — the AWS-free host still exits 0. **All three move Standard-P destructive-cleanup surfaces**; both rows already `pending`. Evidence: `dev check` 0, `test unit` 0 (~~3420~~ + 27 + 33 + 27 — **corrected 2026-08-14**: this figure and Sprint `4.80`'s own `3419` disagreed, and the pre-`4.81` tree measures **3430**), `test integration cli` 57/57. Prior reclose 2026-08-11 on Sprints `4.76`/`4.77` (Standards A/N)** — the own-surface reopen on the destructive lifecycle paths this phase owns closes, and the phase has no open sprints. **Sprint `4.76` ✅ Done (2026-08-11)** is the one to read, because the reported defect was the smallest of four that composed. A `--cascade` run narrated three `unreachable` per-run statuses as "no live per-run residue" and exited 0; underneath, `inferCascadeSubstrate` tested `isResiduePresent`, so an unreadable backend inferred `SubstrateHomeLocal` — precisely the branch on which a skipped drain is success; `clusterReachable :: IO Bool` returned `False` for **every** non-zero `kubectl` exit, so a refused credential was indistinguishable from a departed cluster; and the postflight sweep returned `IO ()`, so nothing it found could reach the exit code. Each is now three-valued with the **uncertain arm as the default**: `ClusterProbe` yields `ClusterAbsent` only on a recognised connection-establishment phrase, and a unit case asserts the closed property that no evidence phrase names an authentication or authorization refusal, because being told `Unauthorized` proves a server answered. `reconcileAbsent` returns an outcome carrying observed-absent and unobserved separately, and `absentReconcileExitCode` fails on a non-empty unobserved set even when every destroy succeeded; the cascade folds six phase outcomes and runs every phase (§ 5c makes drain→destroy an attempt edge, not a barrier). `prodbox nuke` gains the terminal sweep § 5/§ 6b have always assigned it — **and a unit case had pinned its absence**, listing `discoverClusterTaggedAwsResources` among tokens forbidden in `Nuke.hs`, so the gap was an asserted invariant rather than an omission. Its row was also wrong in one place: the `"Per-run Pulumi destroys"` narration is shared with `prodbox aws teardown`'s **`Operational`** batch, so every operator who tore down the IAM user was told "Per-run" about it; the label is now derived from the batch's own `LifecycleClass`. One residual is registered rather than absorbed with a stated reason: the sweep's credential-absent arm stays a skip, because refusing would fail `--cascade` on every host that has never provisioned an AWS substrate — the arm no longer lies, so what is open is policy, not honesty. **Sprint `4.77` ✅ Done (2026-08-11)** closed two defects where its row named one: the AWS CLI parses list-valued options with `store` so a repeated `--tag-filters` sent only the second, and the Tagging API **ANDs** `TagFilters` so even both-sent would have asked for resources carrying *both* tags where the sweep wants either — it is now one query per filter set, unioned by ARN, with any constituent failure failing the whole discovery. The EBS reaper gained a client-side re-filter through `partitionEbsTagRows`, which had **no production caller**, the enforcing-nothing shape Sprints `4.68` and `4.72` also found; `parseTagSweepPayload` stopped returning `Right []` for every payload shape it did not recognise. `--yes` was resolved by **gating rather than removal**, because it is the documented automation entrypoint in `CLAUDE.md` and the `resourceDestroyCommand` string the registry prints in teardown refusals — removing it would have narrowed the automation contract below the doctrine — and confirmation was split from the quietness selector it had silently doubled as. **Both sprints move Standard-P destructive-cleanup and lifecycle-orchestration surfaces**; both rows were already `pending`. Prior state — ✅ **Reclosed 2026-08-10 on Sprints `4.73`-`4.75`**, ending the own-surface reopen on the condition it existed to remove: no `Pending Removal` row on a Phase-`4` surface is unowned. **Sprint `4.74` ✅ Done (2026-08-10)** is the one to read, because its row was wrong in the flattering direction: it said Vault CAS callers could not distinguish a lost race from a transport failure, and measurement found **four callers already classifying and all four wrong the same way** — `HttpStatus 400 -> "conflict"` plus a `409` arm Vault never returns for a KV CAS. Vault answers a version mismatch and a malformed or cas-required request with the same `400`, so `reconcileRetainedAuthorityEpoch` spent an authority-epoch CAS retry on a refused request and then called it a lost race, and `vaultRequestReplayRepository` reported a write that never happened as a replay conflict. The row also named three files against a measured **eleven call sites across ten modules**, the eleventh found by this sprint's own `dev check` rule on its first run rather than by reading. `VaultCasOutcome` now names applied/conflict/refused/unobservable, `classifyVaultCasOutcome` is the one total reading, and a `dev check` rule fails the build for any module writing a CAS without it — stated as what it is, a compiled rule over a source region rather than a property of the type, because the transport result stays `Either HttpError` for the Vault session wrapper's single relogin (§ 22). Retyping the primitive across eleven critical-path sites was declined as the coupled-big-bang shape that required reverting Sprint `4.51`. **This moves a Standard-P persistence-protocol surface.** **Sprint `4.73` ✅ Done (2026-08-10)** routes the SES DNS writer through the typed `DnsRecordProgram`, answering all three obstacles Sprint `4.72` measured: `DnsRecordType` gains CNAME and MX with canonical value forms and `ownerAcceptsType` becomes total over the whole 5 x 4 matrix; the five lanes submit in one burst and discharge propagation afterwards, keeping the batch's single window rather than five in series; and `ensureSesDnsInputs` still runs first so the ensure begins from a conclusive observation. **Its own finding is one the row did not state**: the lane needs its own owner, because sharing `AwsLifecycleProviderDnsOwner` would have made `dnsRecordLifecycleClass` assert `PerRun` about records in the operator's retained parent zone and handed the public A-record writer TXT/CNAME/MX authority over the same zone. **Sprint `4.75` ✅ Done (2026-08-10)** owns the one row that cannot be closed by code and says why in measurements — `dhall/capacity/measured/` holds only `Schema.dhall`, so no profile exists for any lane — while correcting the haddock that called the authored control-plane service time measured. Sprints `4.67`-`4.72` are ✅ **Done** and closed five of the six rows the phase carried into the prior pass. **Sprint `4.68` ✅ Done (2026-08-10)** is the one to read: the accept path was `forever { accept; forkFinally }` — a thread per accepted connection, nothing counting them, no deadline on the read or the interpreter — and the machine that fixes it **already existed with no production consumer**, since `Prodbox.ControlPlane.Capacity` has held an opaque `ServiceCapacityPlan` and a pure decide/evolve `AdmissionQueue` since Sprint `1.62`. The kernel backlog (`listen … 32`) bounds pending connections, not accepted ones, and that distinction is the finding. The deadline is enforced **inside** the response obligation rather than around it, because a `timeout` outside delivers an async exception the obligation answers with its cancellation refusal — the caller would read `503 shutting-down`, naming the wrong cause, and a second write would be a second reply. **Testing the path then found a defect reasoning about it had not**: `close` on a socket with unread bytes sends RST and discards the reply, and the `429` and `408` are exactly the two replies produced without reading, so a bounded drain now precedes the close. Mutation-proven: `rawWorkerCount = 1` fails `dev check` with `ServiceCapacityOverCommitted 2400000`. **This moves Standard-P queueing/admission and deadline-composition surfaces.** **Sprint `4.72` ✅ Done (2026-08-10)** measured the same enforcing-nothing shape on DNS: before it, `runDnsRecordProgram`, `EnsureDnsRecord`, and `DestroyDnsRecord` appeared **only in two unit suites**, so the typed program bounded no running code at all. The public A-record writer now runs `EnsureDnsRecord` against an exact coordinate whose account is observed from `sts get-caller-identity` and whose ownership epoch comes from the retained Authority epoch — observed rather than carried, so a request cannot claim an account and no durable wire format changes. The SES writer is **narrowed into its own row with a measured reason** (three record types against two defined; five records in one batched change with a single propagation wait; desired values that may require creating the SES identity first), which is a redesign rather than a rerouting — and Sprint `4.73` above is the sprint that performed it. **Sprint `4.71` ✅ Done (2026-08-10)** deletes the unconditional `vaultKvWriteV2`, and the audit its row called "its own sprint" found **three real lost-update races**, the worst being a federation child-index read-modify-write where two concurrent registrations silently erased one child; the gateway continuity marker becomes create-only because its own contract already said a latch that can be overwritten is not a latch. **This moves a Standard-P persistence-protocol surface.** **Sprint `4.70` ✅ Done (2026-08-10)** makes a target-sink CAS request unassemblable from raw data, and narrowing the export surface **exposed dead code the `(..)` imports had masked** — seven unused imports and an orphan binding left by Sprint `4.59`. **Sprint `4.69` ✅ Done (2026-08-10)** makes the reconcile run thread its admissions through a fold, so the `fst <$>` that dropped the final slice's set is not expressible. **Sprint `4.67` ✅ Done (2026-08-09)** migrates **56 status projections across 34 files** to the closed `ReplyStatus`, correcting its row's namespace-scoped count of 51, deleting a verbatim second copy of a server's status table in `TlsRetentionAuthorityClient`, and replacing the replay projection's `100..599` range test with a decode refusal. The three rows that pass left — the SES DNS writer, the authored control-plane service time, and the Vault CAS conflict — are closed or owned by Sprints `4.73`-`4.75` above. Prior status: 🔄 Active (2026-08-09) on the unowned `Pending Removal` rows this phase owns; Sprints `4.62`-`4.66` are ✅ **Done** and the reopen stays open because rows this phase owns remain. **Sprint `4.66` ✅ Done (2026-08-09)** is the one to read: `httpReasonPhrase` mapped six statuses while the interpreters emit ten, so the control plane was writing `HTTP/1.1 403 Status` on the wire for every authorization refusal, authentication failure, replay expiry, and cleanup tombstone. The ledger row understated it three ways and each count is corrected by measurement - the unmapped set is `{401, 403, 408, 410}` not `{401, 403}`, 17 sites across 11 files not nine, and 338 producer literals and 75 type sites across 37 files not 47 and 17. `Prodbox.Http.ReplyStatus` holds the closed set with both projections total and `replyStatusFromCode` **derived from** `replyStatusCode` rather than restated, and a `dev check` rule fails the build on drift - proven at repository scale by deleting `ReplyForbidden`, which names 11 real production files. The gate's own first run produced two false positives and both are recorded rather than patched away (`CallerPrincipal`'s `100`-`103` principal tags share the `-> NNN` shape, so the exemption is by path and named; `LocalClient.hs`'s `(127, 0, 0, 1)` matched the reply-tuple shape). **The row is narrowed, not closed**: the producers still answer a raw `Int`, and that measured migration stays open. **Sprint `4.65` ✅ Done (2026-08-09)** gives a refusal back its structured reason, and its row's evidence was false twice over - it prescribed importing `Prodbox.Logging`, a module that has never existed on any branch, and calling `hPutStrLn stderr`, which `dev check` forbids in every `src/Prodbox/**.hs` outside three exempt paths, so following the row as written would have failed the build; it was also filed against a file that never sees the exception. The observation seam is a **positional** argument of `mkResponseObligation`, because a defaulted field would have made observation opt-in and the defect is that nobody opted in. **Sprint `4.64` ✅ Done (2026-08-09)** makes the admission reset Sprint `4.61` fixed by hand **unnameable** - `noAdmissions` is package-internal, `runFirstAnchoredStepOrder` is the sole entry point that starts empty, and the *existing* allowlist bars the way around it rather than a new lint being written; the bound is stated rather than implied, since it stops an accidental reset and not a deliberate one. **Sprint `4.63` ✅ Done (2026-08-09)** decides the global target-intent ledger's CAS verdict at all four sites its row said was one, with the disposition **decided rather than copied** from `4.62`: only `ModelBCasRefusedCorrupt` refuses, because every producer of it refuses before the object store, while `ModelBCasUnobservable` stays deliberately on the read-back path as the applied-but-response-lost case. A second defect fell out - a refusal consumed a compaction retry and surfaced as `TargetCommitCompactionOverBound`, a capacity bound named as the cause of a refusal. Sprint `4.62` ✅ **Done (2026-08-09)** binds the target-sink CAS verdict that was discarded with `_ <-`, and **its ledger row understated the defect**: the mutation exercise shows the pre-fix interpreter returning `TargetCommitRunCommitted { targetCommitRunSinkCasAttempted = True }` for a write the sink store explicitly refused — a false commit record for a target secret, reachable whenever the sink holds the expected bytes for any other reason. `TargetSinkCasRefused` is now the distinct `TargetCommitSinkCasRefused`, because what the sink *said at the time* and what it *looks like afterwards* are different facts and collapsing them is how the refusal became a success; `Applied` / `Conflict` / `Unobservable` stay on the read-back path, the last deliberately, since it is the applied-but-response-lost case. The row's second named location was also stale — `TargetSecretAgentExecution.hs` has zero occurrences since Sprint `4.59` deleted that lane. A co-defect of the same shape on the **global** ledger CAS was found on the same call path and registered rather than absorbed, because the guarded Model-B arms need their own disposition rather than a copied `case`. **Remaining on this reopen**: six unowned rows - the unbounded control-plane accept loop with no per-request or read deadline (the one that moves a Standard-P queueing/admission surface), the producer-side `ReplyStatus` migration Sprint `4.66` narrowed, the two untyped Route 53 writers in `ProviderProduction.hs`, the `TargetSinkCasRequest`/`TargetSinkRecord` constructor exports, the non-CAS `vaultKvWriteV2` export, and the discarded final-slice admission set Sprint `4.64` found while measuring itself. Prior reclose 2026-08-08 on Sprint `4.61` — a second own-surface reopen the same day, closed the same day. Phase 5's Sprint `5.31` made a discarded refusal speak, and the sentence it produced named a Phase-4 defect: `runAnchoredStepOrder` reset its admission set at every phase boundary, so a component whose readiness step is anchored in an earlier phase than its dependant's mutation step was refused unconditionally — "never observed ready in this run" said of a component observed ready earlier in that same run. `applyNativeInstallPlan` now threads admissions bootstrap → transition → steady, and the two interstitial readiness observations record their evidence instead of discarding it. Staleness is untouched: an admission aged past its bound still expires and re-observes, so what widened is which evidence counts, not how long it lasts. A gate holding the threading is owed and registered rather than claimed. Prior status: ✅ **Reclosed 2026-08-08 on Sprint `4.60`**, which gave the control-plane server a response obligation. `runControlPlaneServer` used to discard `forkFinally`'s `Either SomeException ()` with `const`, so any throw from the request read, the readiness resolver, or `interpreterHandle` closed the socket with zero bytes and no `500` — indistinguishable on the wire from a network fault, and the *Distinguishability* class committed at a conversion boundary ([chaos_hardening_doctrine.md § 23](../documents/engineering/chaos_hardening_doctrine.md)). The Bootstrap Broker had held the standard since `2.33`; `Prodbox.Http.ResponseObligation` is now the single implementation both it and the integration fixture server route through, and the only module in the governed set permitted to import `Network.Socket.ByteString` — enforced by a `dev check` rule with a positive anchor. The handler's type is `IO reply`, not `IO ()`, so "handled the connection without answering" does not type-check, and the fallback is a total function of a closed refusal rather than a constant, because production must not put an exception's text on the wire while a fixture server must. `SomeAsyncException` is answered best-effort and re-raised unchanged, since `System.Timeout.Timeout` is asynchronous and converting it to a `500` would silently defeat every enclosing deadline. It moves no Standard-P surface: no process, thread, pool, deadline, or admission decision changes, only which bytes an already-accepted connection receives before the same `close`. Prior status: ✅ **Reclosed on Sprint `4.59` (2026-08-08)** — the 2026-08-05 own-surface reopen closes: Sprints `4.55`, `4.56`, and `4.59` are all Done and Phase `4` has no open sprints. Sprint `4.55` ✅ **Done (2026-08-08)** moves every control-plane role's readiness off the kubelet request path — the seam carries `STM`-typed cached facts instead of an `m Bool`, so backend I/O behind readiness no longer type-checks; the four-valued observation keeps an identity rejection distinct from not-yet-ready; N layers resolve from one snapshot in one transaction, replacing six non-short-circuiting `&&` compositions; and the old seam is deleted. Its **counts were wrong for all five roles** and are corrected against source: the Lifecycle Authority ran five signed S3 LISTs (one store reached from five layers), the two dedicated adapters one each, and the Provider Worker and Target Secret Agent **zero** — the Provider Worker instead shelled out to `aws sts get-caller-identity`, and the Agent ran up to 32 sequential Vault KV reads through an `allM` that short-circuits only on failure, making the healthy path the slowest. Sprint `4.56` ✅ **Done (2026-08-08)** stops the repository minting the right proof and discarding it: `classifyObservation`'s admission ticket now becomes a `DependencyAdmission`, the executor threads an admission set, and a mutating step takes a `MutationAdmission` it cannot be invoked without, re-validated against a bound **read from the graph** — with the honest limitation recorded that every edge derives the same number today, because `componentRequirementSpec` returns one literal. An expired admission re-observes once rather than failing the reconcile, decided explicitly. Sprint `4.59` ✅ **Done (2026-08-08)** deletes the superseded in-controller Target Agent write lane and the `TrustedTargetSink` CAS half it existed to serve; **two clauses of its implementation list were false** and were not executed — `TargetCommitInterpreter.hs` has two registered-suite importers (this plan's own ledger already said the Authority-side call site survives), and the CAS vocabulary is minted by `decideTargetSinkWrite`, so it was never orphaned. Prior status: 🔄 Active (own-surface reopen 2026-08-05) — previously ✅ Reclosed on Sprints `4.50`/`4.53` (2026-08-01).** The retained Authority and five-role runtime, encrypted EKS client-auth, exact TLS retention, Provider-native SES/Route53 reconciliation, decommission protocol, legacy transport deletion, and authenticated S3 endpoint witness are code-owned and independently validated. Current-revision live exercise remains Standard O/P evidence. Own-surface reopen on Sprint `4.54` (2026-08-04) repairs this phase's own validation evidence: Sprint `4.53` rested its Independent Validation on a test module Sprint `4.50` had deleted, and its three endpoint-readiness classifier cases were committed in no revision, so the production-live phrase-to-constructor mapping had only a constructor-name presence scan over it. Coverage is restored on the surviving `ModelBCasTransport` seam (19/19) with a mutation exercise proving it fails closed. **Own-surface reopen 2026-08-05 (Sprint `0.21` topology sweep): 🔄 Active** on Sprints `4.55` (five control-plane roles run six signed S3 LISTs on a `timeoutSeconds: 1` probe path — the Sprint `2.39` defect, unmigrated) and `4.56` (the admission ticket is minted and discarded one line later). Prior reclosures stand. Sprint `4.58` (2026-08-06) closes the target-sink expected-version surface and corrects its own prior account of the defect; Sprint `4.59` is registered 📋 Planned to delete the superseded in-controller Target Agent write lane, which has zero production callers. | Durable Lifecycle Authority, immutable checkpoints, operation journal/outbox, target delivery, authority-epoch cutover, removal of gateway/host-direct authority, crash-safe decommission, durability-indexed retained storage, observed-host over-commit rejection, and typed endpoint-readiness |
| 5 | Canonical Test Suite | ✅ **Reclosed 2026-08-13 on Sprint `5.34` (Standards A/N)** — an own-surface reopen closing this phase's two remaining unowned rows, and **the pass's sharpest finding is that one of them prescribed a check the repository forbids**. The symmetric credential guard — require `access_key_id` to *have* the AWS id shape — refuses this repository's own integration fixtures, and those fixtures cannot carry a valid id because Sprint `1.75`'s `scannedCredentialViolations` fails the build for any **tracked** file with that shape. Two rules in direct opposition; the scanner wins, and the guard keeps the half that matters — a transposition of **real** credentials is refused, placeholders go unremarked. The all-empty-fixture half is closed by **argument** rather than code: `defaultTestSecrets` *is* all-empty, it is what the generated schema's `default` carries, so a decoder refusing empty would refuse the schema's own default. The Tier-0 write gate widened from one line to **one hop within one top-level definition**, and Sprint `5.30` was right that widening risks an unstated bound — two drafts produced false positives before the third was correct, and all are recorded. It found one true escape (`withBinarySiblingTier0`, now typed `Tier0Fixture -> IO a -> IO a`) plus a Standard-C correction: `tier0FixturePath` claimed the sibling filename appears once in the test tree; measured, six files and 109 occurrences. Evidence: `dev check` 0, `test unit` 0 (3420 + 27 + 33 + 27), `test integration cli` 57/57 — load-bearing, because the symmetric draft broke two integration cases and that is how the conflict surfaced. Prior reclose 2026-08-11 on Sprints `5.32`/`5.33` (Standards A/N)** — the own-surface reopen on the suite content this phase owns (Standard M) closes, and the phase has no open sprints. **Sprint `5.32` ✅ Done (2026-08-11)** is the one that changes what the plan may claim: the `LCPC-2026-07-11` reproducer Standard P depends on discarded its `FrozenCounterexampleTrace` to a `_` wildcard and returned a constant that the validation then checked against itself, so `complete` was `True` for every input. The trace now carries per-mechanism dispositions read from `test/qualification/LCPC-2026-07-11.dispositions` — parsed totally over `CounterexampleMechanism`, so a missing or misspelled row refuses rather than silently shrinking coverage — and bound into the trace digest; a committed mutation fixture beside it makes `prodbox test integration control-plane-counterexample` exit non-zero. Two design decisions are recorded rather than glossed: the mutation fixture is deliberately **not** trace-digest-pinned, because pinning it would make the digest gate fire first and the disposition consumption — the thing under test — would never run; and the closure check now runs **before** the evidence artifact, because `mkQualificationEvidence` refuses the same class and, built first, would have left the validation's own fold in exactly the cannot-fail shape this sprint removes. Both Deployment Qualification rows were already `pending`, so **nothing is retracted** — what lifts is the prohibition: the Counterexample column may now be filled by a qualification run, where before it could not be filled by anything. **Sprint `5.33` ✅ Done (2026-08-11)**: `daemon-bootstrap`'s unset arm — byte-identical to its `"pass"` fixture arm one line below — now probes the Bootstrap Broker's route surface with read-only `GET`s and refuses, naming the absent daemon and the address probed, when nothing answers; the audit block declares `AUDIT_PROVENANCE=`. `gateway-partition` renders its values from the composition and **left the integration surface entirely** for the unit suite, which reduces the canonical suite's node count and reduces no coverage — the node declared `-> []` prerequisites and could not fail on any input, while the unit suite additionally pins that its emitted lines change when its composition changes. The eight Phase-`2` sprints citing it, and Sprints `5.14`, `5.19`, and `8.12`, carry Standard-C corrections; no code deliverable is withdrawn. Prior state — ✅ **Reclosed on Sprint `5.31` (2026-08-09).** The installed `cli` and `env` integration suites pass **55/55**, and canonical `prodbox test unit` exits 0 with the main Hspec inventory at **3255/3255**. The final four failures were corrected as fixture drift: the fake cluster's three gateway Pods violated the typed exact-cardinality projection of two; the transient primary image push retries and succeeds without using the fallback; config setup is asserted through the derived Dhall union constructor and structural decode; and the AWS-IAM teardown fixture supplies a valid fixture subzone so it reaches the intended unavailable-Credential-Provisioner refusal. Prior reclosures and their code-owned evidence stand. Clean-room deployment qualification remains `pending` under Standards O/P. | Capability-bound preparation, cleanup-DAG fault tables, temporal CPU/queue/deadline oracle, measured-profile recording, exact peer-SAN validation, and typed three-valued readiness |
| 6 | Final Clean-Room Rerun and Zero-Python Handoff | ✅ **Reclosed on Sprint `6.4` (2026-08-02).** The versioned exact-prefix handoff, rollback refusal, installed-binary plan, and retired-transport absence scan are independently validated; destructive home aggregates remain Standard-P qualification. | Home clean-room cutover/rollback composition, installed-binary migration fixtures, repository absence guards, and zero-residue prerequisite evidence |
| 7 | AWS Substrate Foundations | ✅ **Reclosed on Sprint `7.33` (2026-08-02).** At that closure, role/transport isolation, target-local DNS01, deterministic IAM names, the pure controller-transition algebra, exact public-A Provider intents, and fault dispositions were code-locally validated; owner-UID/child-ARN registration and provider-family cleanup were not production-wired. Sprint `7.35` (2026-08-03) later redacted two real per-run cloud resource ids and completed bootstrap-credential registration. The subsequent corrective work is owned by Sprint `7.36` in the current-status section above; it is not part of this prior closure record. | AWS Broker/Target-Agent/Gateway parity, exact client transport to the single retained home authority, resource isolation, prerequisite fault evidence, and per-run postflight residue narrowing |
| 8 | Operator-Invited Email Authentication via Keycloak + AWS SES | ✅ **Reclosed on Sprint `8.12` (2026-08-02).** The durable SES workflow and invite qualification schema are code-locally complete; live qualification remains Standards O/P. | Durable SES provider revision, narrow mutation fence, credential generation/outbox, and invite fault campaign |

Per-sprint Independent Validation, blockers, deliverables, and Documentation Requirements are
authoritative in the linked phase documents.

## Substrate Parity

Per [development_plan_standards.md → M. Test Suite Substrates](development_plan_standards.md#m-test-suite-substrates),
the canonical test suite is composed of per-substrate runs against both supported substrates,
with no fallback between them (see
[Substrate coverage and independence (no fallback)](development_plan_standards.md#substrate-coverage-and-independence-no-fallback)).
A complete canonical-suite proof requires both the home local and AWS rows below to land
independently against their own target application/platform infrastructure. The AWS row also
depends intentionally on the retained-home Lifecycle Authority and Provider Worker. The authoritative substrate
inventory is [substrates.md](substrates.md); this section is the live tracker for substrate
parity. The authoritative target AWS resource inventory and per-resource lifecycle class
(cleanup-managed per-run stacks whose exact obligations are durably registered/scheduled vs
long-lived cross-substrate shared infrastructure retained by design) live in
[substrates.md → Resource Lifecycle Classes](substrates.md#resource-lifecycle-classes).

| Substrate | Provision | Current teardown and target correction | Suite parity | Teardown prerequisite owner / final parity owner |
|-----------|-----------|----------------------------------------|--------------|-------------------------------------------------|
| Home local | `prodbox cluster reconcile` + `prodbox charts reconcile ...` | Current explicit local-only escape: `prodbox cluster delete --yes`, which makes no AWS claim. Target pending `3.41`/`4.84`–`4.86`/`5.36`/`6.5`, consuming the completed `5.35` oracle: `prodbox cluster delete --cascade --yes` uses bootstrap-owned recovery; `ReadyToUninstallEvidence` admits uninstall from exact convergence and terminal-audit evidence plus the backed-up/read-back report and one-shot permit, while distinct `CascadeCompleteEvidence` additionally requires exact `LocalUninstallEvidence` and the matching read-back receipt. Public activation and legacy deletion are qualification-gated. | **pending.** Must include `TEARDOWN-2026-08-15`, stopped/absent-RKE2 recovery, every interruption prefix, exact `RecoveryPlaneDisposition`, the distinct readiness/completion witnesses, and two consecutive clean-room cycles. | Sprint `6.5` prerequisite / Sprint `8.12` final ([phase 6](phase-6-clean-room-handoff.md)) |
| AWS | `prodbox aws stack eks reconcile` + `prodbox aws stack aws-subzone reconcile` + `prodbox aws stack test reconcile` | Current explicit stack surfaces: the corresponding `prodbox aws stack <cli-verb> destroy --yes` commands. Target pending `7.36`: lifecycle-kernel adapters with exact stack/family read-back, write-ahead manifests, bounded admin-confirmed/read-back adoption manifests for known pre-manifest stacks, a provider-issued EKS drain session, and normalized escape audit. | **pending.** Must prove all three stacks independently, every checkpoint/write-ahead/adoption-manifest arm, AWS/drain unobservability, retained-bucket isolation, exact absence, and repeated cascade. | Sprint `7.36` prerequisite / Sprint `8.12` final ([phase 7](phase-7-aws-substrate-foundations.md)) |

## Deployment Qualification

Per [Standard P](development_plan_standards.md#p-deployment-qualification-and-counterexample-closure),
qualification is revision- and topology-specific. It is not inferred from phase `Done`, a point
readiness response, an older green run, or fake-interpreter evidence.

Both identity columns use Standard P's secret-safe `SourceIdentity`: a versioned, digest-bound
allowlist of code, governed documentation, and non-secret schemas/templates. Its recorded exclusion
policy omits `test-secrets.dhall`, local/generated secret material, secret roots, and runtime/build
roots. Generated-config evidence covers only a canonical non-secret projection. Secret-dependent
runs bind through opaque Authority receipt/generation IDs or Vault-keyed HMAC commitments, never a
public raw hash of plaintext secrets; the evidence digest covers only those public/redacted fields.

| Substrate | Frozen superseded identity (secret-safe source/config/images/topology/wiring/envelope/load identities) | Replacement identity (secret-safe source/config/images/topology/wiring/envelope/load identities) | Canonical commands | Normalized mapping and production profile | Counterexample/fault matrix | Aggregate result | Cleanup/residue result | Start/completion timestamps | Evidence artifact/digest | Status/final owner |
|-----------|------------------------------------------|------------------------------------------|--------------------|---------------------------|-----------------------------|------------------|------------------------|-----------------------------|--------------------------|--------------------|
| Home local | pending complete old-cascade identity bound to `TEARDOWN-2026-08-15` | pending exact recover-to-clean identity | Run `prodbox test all --substrate home-local` twice, then `prodbox cluster delete --cascade --yes` twice under the same qualified replacement identity | Hold background load, ordered fault schedule, and topology-normalized total CPU/memory/ephemeral-storage/persistence constant; record every exact old→new envelope mapping and a separate rendered production profile | `LCPC-2026-07-11`; `TEARDOWN-2026-08-15`; API absent/stopped; caller/RBAC/Vault/MinIO/Authority/backup faults; cancellation/response loss before and after every durable transition | pending | pending exact per-run/family absence, exact intended-retained set with zero unexpected resources, same-run resume, private `ReadyToUninstallEvidence` from the backed-up/read-back pre-uninstall report/permit, distinct `CascadeCompleteEvidence` from exact `LocalUninstallEvidence` plus matching read-back receipt, and exact `RecoveryPlaneDisposition` for every incomplete arm | pending | pending `test/qualification/TEARDOWN-2026-08-15.*` inputs plus complete secret-safe qualification evidence/digest | **pending** (`8.12` final composition; `6.5` teardown prerequisite) |
| AWS | pending complete old global-fallback/checkpoint-kubeconfig identity bound to `TEARDOWN-2026-08-15` | pending exact per-stack/manifest/provider-drain-session identity | Run `prodbox test all --substrate aws` twice; exercise `prodbox aws stack eks destroy --yes`, `prodbox aws stack aws-subzone destroy --yes`, and `prodbox aws stack test destroy --yes`; then run `prodbox cluster delete --cascade --yes` twice | Hold the same four topology-normalized totals, load, and fault schedule; record exact observer/write-ahead-or-confirmed-legacy-manifest/session and old→new envelope mappings plus a separate rendered EKS production profile | Home matrix plus independent stack observation, all checkpoint/write-ahead-manifest arms, every bounded pre-manifest adoption confirm/read-back/refusal arm, EKS session binding, controller-family backstop, AWS unobservability, and duplicate/paginated tag rows | pending | pending exact stack/EBS/DNS/IAM/family absence; exact intended-retained set once and never per-run; same-scope backed-up report and local completion evidence | pending | pending `TEARDOWN-2026-08-15` inputs plus complete secret-safe AWS evidence/digest | **pending** (`8.12` final composition; `7.36` teardown prerequisite) |

Any change to process topology, capability wiring, deadline algebra, resource envelopes,
persistence, lifecycle orchestration, or cleanup invalidates a prior `proven` row.

**Registered 2026-08-14 — Sprints `4.81` and `4.82` both move Standard-P destructive-cleanup
surfaces.** Both rows are already `pending`, so nothing is retracted; what is recorded is that no
qualification identity captured before those sprints land can satisfy either row afterwards, because
`4.82` changes what `prodbox cluster delete --cascade` does on an unobservable control plane and
therefore changes the cleanup/residue column directly. A qualification run must exercise the
post-`4.82` cascade, and its Cleanup/residue cell must distinguish which layer confirmed absence —
recording a bare "clean" would reintroduce at the evidence layer precisely the collapse those sprints
exist to remove. Sprint `2.47` ✅ closed blocker 3 below on its code-owned surface (2026-08-14), which is what stopped the
first campaign attempt. Its live proof and Sprint `2.48`'s are both taken and passed; Sprint `2.50`'s
forward proof — the bring-up advancing past the durable-checkpoint refusal to an initialized Vault —
is the one still outstanding, and it is the same bring-up the next campaign attempt begins with rather
than a separate exercise.

**Correction 2026-08-15 — the Sprint `4.82` acceptance criterion was taken and falsified.** A
global audit answer was neither lifecycle-partitioned nor keyed to a stack: AWS returned one
`ResourceTagMapping` for the retained bucket with its full two-tag set, Prodbox's decoder emitted
two internal rows, narrated them as two resources, and copied that answer to three stack identities
whose exact observations remained `Unobservable`. Postflight correctly partitioned both internal
rows retained and rendered the ARN once. The old proof identity is now the frozen superseded side of the teardown
counterexample; it cannot satisfy either qualification row. The replacement rows require exact
key/scope/cardinality, minimal recovery, write-ahead and confirmed-legacy ownership-manifest
recovery, stable-run resume, backed-up
pre-uninstall readiness, uninstall-last, and scoped post-uninstall completion evidence.

### First campaign attempt (2026-08-13) — home local

**The campaign was started and has not completed. What it found is recorded here because it is the
first evidence in this plan produced by running the composed system rather than reading it.** Three
distinct blockers surfaced, in order, each invisible to `dev check`, the unit suite, and the
integration suites:

| # | Blocker | Disposition |
|---|---|---|
| 1 | The registry mirror path published a whole multi-architecture manifest index, so `cert-manager` could not be mirrored | **Fixed** — Sprint `3.36`; proven live by seven publications across both callers |
| 2 | The pinned `cert-manager` `v1.16.2` upstream artifact is itself unpublishable | **Fixed** — Sprint `3.37`; pin moved to `v1.17.1`, all five images verified |
| 3 | `prodbox vault init` fail-closes: the Bootstrap Broker refuses the secret-bearing physical call as having *"bypassed its attested one-shot worker"*, and **no SecretWorker Job is ever created** | **Closed on the code-owned surface** — Sprints `2.47` ✅, `2.48` ✅, `2.49` ✅, and `2.50` ✅ Done (2026-08-14); forward live proof 🧪 pending (Standard O). Root cause was re-diagnosed by Sprints `2.46`/`2.47`: the refusal is a preserved `bootstrap-session-fence`, not an unwired SecretWorker. **Four distinct defects sat behind one another on this path, and each was only reachable once its predecessor was fixed** — a fence that could never be retired (`2.47`), a Lease that could never be created because Kubernetes parses `renewTime` as a six-digit `MicroTime` (`2.48`), an attestation and a secret-worker refusal that named none of their causes (`2.49`), and a durable pre-receipt checkpoint from a superseded fence generation that no later invocation could match (`2.50`). Each was found within one build of making the preceding refusal say more, which is why the narration work is recorded as load-bearing rather than cosmetic. See the ledger rows. |

**Blocker 3 is an architecture gap, not a patch.** The reproduction is exact and repeatable through
the canonical entrypoint: `prodbox vault init` exits 1 with
`HTTP 409 {"status":"boundary-refused"}`, Vault stays uninitialized
(`security barrier not initialized`), and `kubectl get jobs -A` shows the only Jobs in the cluster
are RKE2's own `helm-install-*`. The refusal is raised by the *direct* physical interpreter
(`secretWorkerBypassRefused` in `src/Prodbox/Bootstrap/Broker/ProductionEngine.hs`), which means the
call never reached `runAuthorizedSecretWorkerPhysical`'s worker branch — so the attested one-shot
SecretWorker path that Sprints `2.33`/`2.36` designed is not exercised on the live bring-up path.
The guard itself is correct and fail-closed; what is missing is the path it is guarding.

**Two observability defects made this harder to diagnose than it should have been, and both are
worth their own work.** First, `boundaryReply` in
`src/Prodbox/Bootstrap/Broker/EngineAdapter.hs` discards the refusal detail —
`EngineBoundaryRefused _` — so the operator receives `{"status":"boundary-refused"}` and the reason
exists only in the source. Second, the broker pod emits **zero bytes of log output**, so the reason
is not recoverable from the running system either. A fail-closed boundary on the critical bring-up
path that refuses without saying why, in a service that logs nothing, is the *Distinguishability*
class of [chaos_hardening_doctrine.md § 21](../documents/engineering/chaos_hardening_doctrine.md).

**Nothing in the table below moves.** Both substrate rows stay `pending`; no column is filled by a
run that did not complete, and the AWS substrate was not attempted.

**The `LCPC-2026-07-11` reproducer became falsifying on 2026-08-11 (Sprint `5.32` ✅).** Standard P's
counterexample rule requires a repository-owned reproducer that records an *expected failure against
the frozen superseded implementation*. Until this sprint the named reproducer,
`simulateFrozenCounterexample` in `src/Prodbox/Test/Qualification/FrozenCounterexample.hs`, discarded
its `FrozenCounterexampleTrace` argument to a `_` wildcard and returned a constant built by its own
`simulateComposition`; `src/Prodbox/Test/CounterexampleValidation.hs` then asserted exactly what that
constant contained. Both the five superseded failures and the five replacement closures were produced
by the module that checked them, and no input could make the node fail — the exact failure this
section's header excludes by name ("not inferred from … fake-interpreter evidence"), reached through
the mechanism meant to enforce it.

The frozen trace now carries per-mechanism dispositions read from
`test/qualification/LCPC-2026-07-11.dispositions` and bound into the trace digest, and a committed
mutation fixture beside it makes `prodbox test integration control-plane-counterexample` exit
non-zero. Because both rows above were already `pending`, **no `proven` claim rested on the old
behaviour and nothing is retracted.** What changes is the standing prohibition: the
Counterexample/fault-matrix column of either row **may now be filled by a qualification run**, where
before it could not be filled by anything. Both columns stay `pending` because no such run has
happened — that is the Standard-P campaign, not this sprint.

Sprint `0.29` **does** touch a Standard-P surface, and it is the sharpest of the recent set: it
changes the content of **every** generated `prodbox.dhall` by stamping a content-derived `witness`,
which is a generated-config-identity change by the enumeration above. Both substrate rows are already
`pending`, so nothing is invalidated, but a `proven` row may only bind a generated-config identity
captured **after** `0.29`. A practical corollary for whoever runs the campaign: any
`prodbox.dhall` on disk from before this sprint carries `witness = []` and now fails the Tier-0 drift
gate, and `prodbox config generate` is idempotent — the remedy is to remove the file and regenerate,
not to generate over it. Sprints `0.27` and `0.28` move no production-composition surface; they are
plan metadata and developer tooling.

Sprint `3.34` **does** touch a Standard-P surface: it changes the rendered NetworkPolicy egress of
two charts and of the generated `target-secret-agent-kubernetes-api` policy, which is capability
wiring by the enumeration above — the same reading recorded for Sprint `0.19`, which deleted
credential environment entries from rendered manifests. Both substrate rows are already `pending`, so
nothing is invalidated, but the next qualification run must exercise the post-`3.34` rendering rather
than an earlier one. Sprint `4.76` likewise touches **destructive cleanup and lifecycle
orchestration**, both named in the enumeration: the cascade now folds phase outcomes and refuses on
an unobserved per-run stack, `prodbox nuke` gained a terminal fail-closed tag sweep, and the K8s
**Four of the 2026-08-13 sprints move Standard-P surfaces, and all four are recorded here rather
than left to be inferred.** Sprint `2.45` moves a **persistence-protocol** surface: no wire format,
key, or envelope changes, but a Bootstrap-Broker durable read that previously returned a
structurally-decodable but semantically-wrong record now returns `BootstrapStoreCorrupt`. Sprints
`4.78`, `4.79`, and `4.80` move **destructive-cleanup** surfaces, all three in the narrowing
direction: messages that classified as *absent* on an unanchored numeral now classify as
*unobserved*; two destroy paths report or refuse where they previously reported completion; and the
cascade sweep's credential-absent arm fails when this lifecycle had AWS state in scope. **No
resource is destroyed that was not destroyed before** — what changes is that fewer absences are
presumed. Both substrate rows are already `pending`, so nothing is invalidated; a future
qualification run must exercise the post-`4.80` teardown and must not carry forward a
cleanup/residue result recorded when these paths could report an absence they had not observed.
Sprints `1.87`, `1.88`, `3.35`, and `5.34` move no enumerated surface: the first three are
provenance and ownership changes with byte-identical rendered output (verified for `3.35` by a unit
case comparing the rendered URL to its literal form, and for `1.88` by a live
`prodbox cluster status` run), and `5.34` touches only test-harness fixtures and developer tooling.

drain aborts on an undecidable cluster probe. Sprint `4.77` touches the same destructive-cleanup
surface through the corrected AWS argv and the now-load-bearing `--yes`. A future qualification run
must exercise the post-`4.76`/`4.77` teardown, and in particular must not carry forward a
cleanup/residue result recorded when the sweep could not fail. Sprint `2.42` changes a readiness
*reason string* and neither the verdict nor any manifest, and moves no enumerated surface. Sprints
`5.32` and `5.33` change what qualification *inputs* can fail rather than any production
composition; `5.33` additionally removes `gateway-partition` from `canonicalNativeValidations`, which
changes the canonical command's node set and so must be reflected in the commands a `proven` row
records. Sprint `0.26` changes governed documentation only — though note that `SourceIdentity` binds
governed documentation, so a doctrine edit still moves the source-manifest digest a future `proven`
row would bind. Separately, and more concretely than the standing `pending` status: **the
AWS-substrate suite's last recorded run did not complete**, being blocked at the `bootstrap-broker`
release by the defect Sprint `3.34` has since fixed; no run has been attempted at the current
revision.

The
resource-governance sprints `1.68`/`1.69`/`1.70`/`3.28`/`3.29`/`3.27`/`4.52` change the
**resource-envelope / persistence / substrate-routing** surface named in that clause — the decode gate,
single-sourced PVC storage, derived namespace quotas, and observed-host dual-device recompile; both rows
are already `pending`, so nothing flips to un-proven, but each carries `Deployment qualification: pending`
and the current revision must not be called deployment-ready on the strength of the new compile-time
proofs alone. The live proof (an over-committed config refused at decode, an undersized host refused at
reconcile, and derived quotas admitting every real PVC on a running cluster) is a Standard-O axis for the
next `prodbox test all` on each substrate.

Sprint `2.37` (2026-07-30) makes the cutover-target `JournalLeaseEmitter`'s retained-assertion
(unacked-suffix) memory-leak class **non-constructible** — the mechanism behind the 2026-07-29 live
gateway OOM cycle. This advances the Standard-P leak-free requirement for the target emitter but does not
flip either row: both remain **pending**. The live evidence — a healthy long-run (≥ the prior ~2.4h
OOM interval) `JournalLeaseEmitter` run holding a bounded resident set under a stalled-signer/
unreachable-peer fault, exercised through the required aggregate/fault campaign — is the outstanding
Standard-O/P axis, and the current revision must not be called leak-free or deployment-ready on the
strength of the compile-time non-constructibility proof alone.

Sprint `0.19` **does** touch a Standard-P surface, and the earlier claim that it did not was wrong:
it deleted the credential environment entries from the rendered EKS image-push Pod and image-mirror
Job manifests and removed a `kubectl exec` login step from the push orchestration. That is capability
wiring by Standard P's own enumeration. Both substrate rows are already `pending`, so nothing is
invalidated — but the next qualification run must exercise the post-`0.19` manifests, not an earlier
rendering.

Sprint `2.38` (2026-08-04) **does** touch a Standard-P surface — broker shutdown is lifecycle
orchestration. It replaces an unreachable shutdown postcondition (`Map.null entries`, which a
retained replay binding makes permanently false) with the reachable property it was meant to express,
removing a permanent graceful-drain deadlock that a following force-drain could not break. Both
substrate rows are already `pending`, so nothing is invalidated, but the next qualification run must
exercise the post-`2.38` shutdown path, and the current revision must not be called deployment-ready
on the strength of the focused broker suite alone. Sprints `1.75`, `4.54`, and `5.27` (same date)
touch no production-composition surface: a lint over tracked source, a restored unit module, and a
test-fixture teardown respectively.

Sprints `4.55`, `4.56`, and `5.29` (2026-08-08) **do** touch Standard-P surfaces, and both rows are
already `pending`, so nothing is invalidated — but the next qualification run must exercise the
post-change behaviour, not an earlier one:

- **`4.55` changes readiness semantics.** A role's `/readyz` now folds a latched record instead of
  performing backend I/O, and it fails closed on a cold start and again once the record passes the
  derived 20-second staleness bound. The live axis is a role Pod answering inside the chart's
  `timeoutSeconds: 1` budget, and a stalled observer evicting the Pod rather than pinning a stale
  `ready`.
- **`4.56` changes lifecycle orchestration.** A mutating reconcile step now requires an admission,
  and an expired one re-observes before it refuses. The live axis is a reconcile crossing a phase
  boundary — federated Vault unseal and a settings reload — without the re-observation turning a
  routine boundary into a run failure.
- **`5.29` changes destructive cleanup.** An always-run Challenge deletion node enters the cleanup
  DAG and fails closed on an unobservable read-back. The live axis is the first run against the
  operator-owned parent zone: any pre-existing leaked `_acme-challenge` TXT will turn the postflight
  red, which is the intended behaviour and should not be read as a regression.

Sprint `4.62` (2026-08-09) **does** move a Standard-P surface — persistence protocol. A
target-secret commit that the sink store explicitly refused is no longer recorded as committed, so
what changes is *when a commit counts as a commit*. Both substrate rows are already `pending`, so
nothing is invalidated, but the next qualification run must exercise the post-`4.62` commit path, in
which a refused CAS surfaces as `TargetCommitSinkCasRefused` instead of being absorbed by the
following read-back. The `Unobservable` arm is deliberately unchanged and stays on the read-back
path: it is the applied-but-response-lost case, and routing it to a refusal would reintroduce the
"unobservable is not absent" defect Sprints `4.53` and `5.29` closed elsewhere.

Sprint `4.63` (2026-08-09) **does** move a Standard-P surface — persistence protocol, the same one
Sprint `4.62` moved one store along. A target-intent completion the **global** ledger refused is no
longer recorded as committed, so *when a commit counts as a commit* changes on the global lane too.
Both substrate rows are already `pending`, so nothing is invalidated, but the next qualification run
must exercise the post-`4.63` commit path, in which a refused CAS surfaces as
`TargetCommitGlobalCasRefused` carrying the ledger step, and a compaction refusal no longer consumes
a retry and then reports `TargetCommitCompactionOverBound`. As in `4.62`, the `Unobservable` arm is
deliberately unchanged and stays on the read-back path.

Sprints `4.64`, `4.65`, and `4.66` (2026-08-09) touch **no** Standard-P production-composition
surface, and the reasoning differs enough per sprint to state rather than assert collectively.

- **`4.64` changes which values a call site can name, not what a run does.** The same admissions are
  threaded through the same phases in the same order; `noAdmissions` simply cannot be written at a
  phase boundary any more. No process, deadline, envelope, or admission *decision* moves.
- **`4.65` adds a write to the process's own stderr and changes no wire byte.** The reply a peer
  receives is identical before and after. What is new is that the refusal's reason is recorded
  server-side, which is what
  [bootstrap_readiness_doctrine.md § 0.5](../documents/engineering/bootstrap_readiness_doctrine.md)
  already required. Adding an observation where there was none cannot invalidate a qualification
  claim, because nothing could have depended on the silence — the same reasoning Sprint `5.30`'s
  diagnostic line rested on.
- **`4.66` changes a reason phrase, not a status.** A `403` is still a `403`; the four bytes after it
  stop reading `Status` and start reading `Forbidden`. No client behaviour keys on a reason phrase in
  HTTP/1.1, and none of Standard P's enumerated surfaces moves. The next qualification run should
  nonetheless exercise the post-`4.66` wire, because the status line is what an operator reads out of
  a packet capture and it now says something different.

Sprint `3.33` (2026-08-09) **does** edit a live production write path — the gateway daemon's home
Route 53 A-record ensure — and the distinction from `3.32` is worth stating rather than collapsing.
`3.32` was a runtime no-op because `DestroyDnsRecord` has zero production construction sites;
`EnsureDnsRecord` has exactly one. What makes `3.33` still not a behaviour change is that the
authority the daemon now mints is `HomeGatewayDnsOwner`, precisely the owner `homeDnsProgramInputs`
already builds the coordinate with, so the added guard cannot fire on the supported path: no record,
value, TTL, ordering, deadline, or admission decision changes. None of Standard P's enumerated
surfaces moves. Both rows are already `pending`, so nothing is invalidated — but the next
qualification run must exercise the post-`3.33` write path, in which a role the
`RuntimeRole` × `Substrate` table does not entitle receives a typed refusal instead of writing.

Sprints `3.32` and `4.59` (same date) touch **no** Standard-P production-composition surface:
`DestroyDnsRecord` has zero production construction sites, so `3.32`'s arity change is a runtime
no-op, and every export `4.59` removed had zero production references before removal.

Sprints `0.25`, `5.30`, and `4.60` (2026-08-08) likewise touch **no** Standard-P
production-composition surface, and the reasoning differs enough per sprint to be worth stating
rather than asserted collectively. `0.25` is documentation only. `5.30` changes test fixtures, a
`dev check` rule, and a build flag — it adds `--enable-tests` to the canonical build, which widens
what is *compiled* without changing what is *shipped*. Its one production edit is a diagnostic line
in `src/Prodbox/TestRunner.hs` naming a failed runbook step, on a path that previously printed
nothing; adding output where there was none cannot invalidate a qualification claim, because nothing
could have depended on the silence. `4.60` is the one that needs care, because it
edits a live control-plane serving path: it adds no process, thread, pool, deadline, or admission
decision, and changes only **which bytes an already-accepted connection receives before the same
`close`** — a connection that previously got zero bytes now gets a `500` or `503`. None of Standard
P's enumerated surfaces (process topology, capability wiring, absolute-deadline composition,
queueing/admission, resource envelopes, persistence protocol, lifecycle orchestration, destructive
cleanup, substrate routing) moves. Both rows stay `pending`, so nothing is invalidated — but the
next qualification run must exercise the post-`4.60` response path, and the deliberately deferred
items that *would* move admission (a bounded worker pool, `429` backpressure, and a per-request
deadline for `runControlPlaneServer`) are registered in
[legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md) rather than folded in.

Sprints `1.82` and `1.83` (2026-08-09) touch **no** Standard-P production-composition surface, and the
reasoning differs per sprint enough to state rather than assert collectively.

- **`1.82` adds a refusal to the Tier-0 decode path.** No envelope, image reference, resolved
  topology, deadline, or admission decision changes. A Tier-0 file that was already forbidden by
  contract now fails to load instead of loading, and the accepting case is proven rather than
  assumed — every generated `prodbox.dhall` still decodes. The next qualification run must exercise
  the post-`1.82` decode, which is the same decode for every valid file.
- **`1.83` changes where a parse happens, not what it produces.** The rendered certificate
  `dnsNames`, the TLS retention key, and the served host are computed from the same parse as before;
  it now happens once at validation instead of once per consumer. The unit case pins that equality on
  both substrates directly, so the claim rests on a comparison rather than on inspection. Two
  differences are real and are stated rather than rounded off. The first is a refusal, not a value: a
  caller asking for the AWS served host of a locally-validated config now receives a `Left` where it
  previously received `""`. The second was found by **reading `mkFqdn` rather than assuming it** —
  it applies `Text.toLower` as well as `Text.strip`, so a mixed-case `domain.demo_fqdn` now reaches
  the renderers lowercased. That is a no-op on the supported path, whose hostname is already
  lowercase, and where it is not a no-op it removes a latent disagreement (the scope set was already
  built through `mkFqdn`, so the served host and its own SANs could differ in case) rather than
  introducing one.

Sprint `0.20` and the companion own-surface reopens (`1.74`, `5.26`, `7.35`) touch **no** Standard-P
production-composition surface: process topology, capability wiring, deadline composition,
queueing/admission, resource envelopes, persistence protocol, lifecycle orchestration, destructive
cleanup, and substrate routing are all unchanged. One consequence must be recorded rather than
assumed: `SourceIdentity` binds a
digest-bound allowlist that includes **governed documentation**, so retitling `vault_doctrine.md` §20,
amending §6.1/§17, and editing the phase suite change the source-manifest digest a future `proven`
row would bind. Because both rows are already `pending`, nothing breaks — but any later qualification
run must bind the post-`0.20` manifest, not an earlier one. The remediated committed values
(reserved-range addresses, descriptive Kubernetes UIDs, redacted per-run cloud resource ids) are
fixture and narrative data only; none participates in a rendered envelope, image reference, or
resolved topology.

## Superseded Paused-Status Record

**Historical status recorded at the 2026-08-16 paused checkpoint: Phases `3`, `4`, `5`, and `7` were
Active; Phase `6` was Blocked by its explicit earlier-phase prerequisites; Phases `0`, `1`, `2`,
and `8` were closed.** That checkpoint recorded a different interleaved closure narrative; it is
preserved as history and must not be used to resume work. Current ordering lives only in
[Resume Here](#resume-here). Live home/AWS destructive campaigns were non-blocking qualification
evidence and did not substitute for phase-local validation or authorize public activation and
legacy deletion without matching current-revision qualification.

At that checkpoint, the old cascade remained the active public writer and Pending Removal; it was
not accepted as the target recovery path. The new descriptor-bound dispatcher was not wired into
Runtime, `TestRunner`, or the CLI, and the locked `Prepared -> Absent` host record plus exact
read-back remained required before completion could be constructed. An incomplete
replacement returns a stable `CleanupRunId`, exact failures, and a `RecoveryPlaneDisposition`
(`Established`, `NotEstablished`, or `Lost`); it claims a live recovery plane only in the first
case. `ReadyToUninstallEvidence` requires exact clean observations, the exact intended-retained set,
a backed-up pre-uninstall report, and a one-shot permit. `CascadeCompleteEvidence` additionally
requires exact host absence plus the matching read-back local-completion receipt. The 2026-08-15
run is stable counterexample `TEARDOWN-2026-08-15` for Standard P.

### Earlier current-status record

**All nine phases are closed on their code-owned surfaces (2026-08-14). One sprint is open —
Sprint `2.51` 🔄 — and it was opened by a live proof rather than by a failure to finish.** Sprints
`2.48` ✅ and `2.50` ✅ closed last; `2.50`'s forward proof then advanced the bring-up past the durable
checkpoint and failed at a fifth defect in the same chain, a worker image pinned to a config digest
where a registry can only resolve a manifest digest. An Active sprint working a `Pending Removal` row
is the shape Standard I describes, not a reopen (Standard N), so every phase stays ✅. `2.50` closes the durable secret-worker checkpoint that had become the first
blocker on the bring-up path — a pre-receipt checkpoint from a strictly superseded fence generation is
now rolled rather than refused forever — and `2.48` closes both items it carried, the declared Lease
TTL derivation and the compensating release for a fence its own acquisition could not make usable.
Sprint `2.47` ✅ closed earlier the same day, taking with it the plan's oldest open defect: the
Bootstrap Broker now retires a positively-expired fence and re-acquires, so a bring-up abandoned
partway no longer wedges the host permanently.
Earlier the same day Phase `4` reopened and reclosed on Sprints `4.81` ✅ and `4.82` ✅ — opened by a
doctrine gap rather than a failure:
[chaos_hardening_doctrine.md § 24](../documents/engineering/chaos_hardening_doctrine.md) requires an
observation to name its layer, `ResidueStatus` had no field in which to do so, and
[Standard L](development_plan_standards.md#l-cli-doctrine-alignment) forbids closing such a gap
without a sprint block.

**Sprint `2.47`'s live proof is taken and passed** (2026-08-14, five consecutive bring-ups on the
operator host, three fence generations retired). Sprint `2.48`'s is likewise taken and passed — the
fence Lease exists in the cluster for the first time — and the third defect that run surfaced, a fence
leaked when `ensureLease` fails after the CAS, is now compensated rather than merely self-healing.
Sprint `2.50`'s live proof is **taken and passed on the arm it changed**: the durable checkpoint was
rewritten from store version 2 at fence generation 7 to version 4 at generation 13, which is the roll
this sprint widened and nothing else in the tree writes that object. The bring-up did not reach an
initialized Vault, and the defect that stopped it is Sprint `2.51`'s rather than a shortfall of
`2.50`'s — a live proof covers the states it actually reached, which is the lesson `2.49` recorded.
`4.82`'s inverse-of-`4.76` reproduction against a stopped API server remains 🧪 Standard-O pending and
gates nothing. `2.47` and `4.81`/`4.82` all move Standard-P persistence/lifecycle/destructive-cleanup
surfaces, so both substrate qualification rows stay `pending`: a passed sprint proof is not a
qualification run.

Phase `1` reclosed most recently on Sprint `1.89`, which closed the
`Pending Removal` row Sprint `1.88` had re-scoped that morning — the ledger's last unowned row — by
giving the Tier-0 coordinates a retained parse on `ValidatedSettings`, with the Dhall wire format
byte-identical and therefore no generated-config identity change. It recorded two new unowned
residuals in the same pass, so the unowned count is **2**, not zero. Earlier the same day Phase `4`
reclosed on Sprints `4.78`/`4.79`/`4.80` and Phase `5` on Sprint `5.34`,
ending the own-surface reopens that took the unowned `Pending Removal` count to **1**. Phase `2`
reclosed on Sprint `2.45` and Phase `3` on Sprint `3.35`. Phase `1` reclosed on Sprints `1.87` and `1.88`, ending an own-surface reopen that
closed the re-scoped successor Sprint `1.84` had registered against itself and gave
`ValidatedSettings` one production constructor. Phase `2` reclosed on Sprint `2.45`, which deleted
the `validValue _ = True` predicate that made `BootstrapStoreCorrupt` unreachable for seven durable
payload types. On 2026-08-12 Phases `0`, `1`, and
`2` reopened and reclosed on Sprints `0.27`, `0.28`, `0.29`, `1.84`, `1.85`, `1.86`, and `2.44`.
Earlier, Phase `4` reclosed on Sprints `4.76`/`4.77` and Phase `5` on `5.32`/`5.33`, ending the two
own-surface reopens the 2026-08-11 MISU audit registered; the same day Sprint `3.34` ✅ owned the
Kubernetes API egress coordinate that had failed a live `prodbox test all --substrate aws` run at
the `bootstrap-broker` Helm release eight consecutive times, Sprint `2.42` ✅ owned the broker's
discarded transport failure, and Sprint `2.43` ✅ the three broker-readiness defects fixing the chart
exposed. Governance Sprint `0.26` ✅ landed the doctrine `3.34` implements, on the already-reclosed
Phase `0` surface with no reclose event.

**A Standard-J correction landed with this entry.** This section still read "2026-08-11, second
entry" and cited main Hspec **3374/3374** after the 2026-08-12 pass had closed seven sprints and
moved the count; the then-current closure and phase-overview records had been updated and this one
had not. It is corrected in place rather than silently replaced, because the divergence is the kind Standard
J exists to prevent.

`prodbox dev check` / `dev docs check` / `dev lint docs` exit 0, canonical `prodbox test unit` exits
0 at main Hspec **3430/3430** (plus 27/27, 33/33, and 27/27), and installed
`prodbox test integration cli` passes **57/57** and `env` exits 0 — all six gates re-run against the
tree containing Sprints `1.89`, `3.36`, and `3.37` together. Sprint `1.89` adds the ten main Hspec
cases; the integration count is unchanged, which is the expected shape for a decode-time guarantee
that moves no rendered output.

**Sprint `3.36` broke six integration cases before it was green, and the record is kept because the
defect was in the fixture.** `fakeRke2DockerScript` read the image reference positionally, so a
correct `--platform` argv presented as `manifest unknown`; the same script's `save` arm already
parsed flags in a loop, so the file held both idioms and the wrong one sat on the two verbs the
sprint touched.

**One process note is recorded because it cost a validation run.** The pre-work integration baseline
for this pass was taken while source edits were in flight, and the suite rebuilds the library — so it
reported eight failures that were compile errors from a half-finished edit, not a regression. The
figures above are from a clean run after the sprint landed. The lesson is the ordinary one: a
validating suite and an editor may not share a worktree.

**Two statements are made sharper than the standing Standards O/P status, because both are
measurable and neither is inferred.** First, `prodbox test integration cli` was failing **8 of 55**
at the start of this pass — Sprint `3.34` made `endpoints/kubernetes` a live observation and closed
on `dev check` + `test unit` evidence without running the integration suite, and neither fake
`kubectl` served it; the failing set was identical before and after the `4.76` code, and both
boundaries are fixed here. Second, **the AWS-substrate canonical suite has not been re-attempted at
this revision.** Its last recorded run was blocked at the broker on the defect Sprint `3.34` has
since fixed, so "does not currently complete" would now be a claim about a run nobody has made;
what is true is that no AWS-substrate run exists for the current revision. Clean-room deployment
qualification remains pending on both substrates as the distinct Standards O/P axis.

**The remaining plan work is not a sprint backlog but two named axes**, and they must be worked in
that order because the first invalidates the second:

1. The `Pending Removal` ledger (Exit Definition item 33). **Seventeen of its rows carried no owning
   sprint** when the count was taken on 2026-08-09. Sprints `1.82`, `1.83`, `3.33`, and `4.62` took it
   to **15**; Sprints `4.63`–`4.66` then moved three more to `Completed`, struck one as stale,
   re-scoped one that stays open, and added one discovered by doing the work — **15 → 12**. Sprints
   `4.67`–`4.72` took it to **9**, and Sprints `4.73`–`4.75` to **6** — two closed, one given an
   owning sprint as a Standard-O recorder axis, none created. The 2026-08-11 MISU audit then **added
   ten rows, seven of them unowned**, taking the count to **14**; Sprints `4.76`, `4.77`, `5.32`, and
   `5.33` closed every owned row and added two unowned residuals, taking the unowned count to **16**.
   Sprints `0.27`–`2.44` (2026-08-12) took it **16 → 9**, and Sprint `1.87` (2026-08-13) to **8**;
   Sprint `1.88` split one of the remaining eight, closing half of it in place, Sprints `2.45`,
   `3.35`, `4.78`, `4.79`, `4.80`, and `5.34` took it to **1**, and Sprint `1.89` closed that last
   one while recording two residuals it declined to absorb — so the pending total rises 63 → 64 and
   the unowned count 1 → 2.
   The count rising while the work lands is the honest shape here, not a
   regression: an audit that finds more than one sprint can close records what it found, and each
   residual carries the measurement that made absorbing it the wrong call.
   **The pending and unowned totals are derived, and this paragraph no longer carries a copy of
   them.** The one-line derivation and the current figures live in
   [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md), which is their single source
   of truth; restating them here is what
   [documentation_standards.md § 1](../documents/documentation_standards.md) forbids — "a fact that
   can be derived from another document is derived, never copied" — and it is how the figure this
   paragraph used to carry (`73`, then `66`) went stale twice. **Corrected 2026-08-14**: the copy
   previously here read "**66** rows, of which **4** carry no owning sprint", claiming derivation in
   the same sentence that restated a number; run against the table at that moment the command yields
   65 and 3. The remedy is the link, not a fresher copy.
   The rows are worked in phase-numerical order as own-surface reopens (Standard A), which is why a
   closed phase reopening is the expected shape of progress. **Phase `4` reopened and reclosed on
   Sprints `4.81` ✅ and `4.82` ✅ the same day (own-surface reopen, 2026-08-14); every phase is
   reclosed.**
   Sprints `2.47` ✅, `2.48` ✅, `2.49` ✅, and `2.50` ✅ all closed on Phase `2` surfaces without
   reopening that phase, because a sprint working a `Pending Removal` row is not a reopen
   (Standard N). The unowned rows
   remaining are Sprint `1.89`'s Phase-`7` residual — provisioning functions that take a bare
   `ConfigFile` and validate it internally — and Sprint `3.37`'s: cert-manager is the only mirrored
   platform component with no fallback source, which is what turned one broken upstream artifact into
   a forced component-image identity change. The bootstrap-fence row that stood beside them is
   **closed** by Sprint `2.47`; the second blocker it had recorded but never owned became a row of
   its own under Sprint `2.48` and is **closed with that sprint** rather than outliving it, which is
   the orphan shape this plan has now caught three times.
   One earlier row was closed by being **refuted** rather than fixed: the row asserting
   `prodbox test integration cli` fails 20 of 55 was measured against a baseline Sprint `5.31` had
   already repaired. That refutation stood, and then stopped being true for an unrelated reason —
   Sprint `3.34` broke the same suite 8/55 on 2026-08-11, which Sprint `4.76` found while validating
   and fixed. Both facts are recorded rather than the later one silently replacing the earlier.
2. The Standard-P qualification campaign (Exit Definition items 32, 47, 48) — two consecutive
   `prodbox test all` runs per substrate with the required load, fault, cancellation, response-loss,
   and cleanup matrix. It is deliberately **last**: Standard P invalidates a `proven` row on any
   change to the surfaces the ledger rows sit on, so qualifying before the ledger closes would
   qualify a revision the next sprint replaces.

   **The campaign was started on 2026-08-13 and immediately justified its own ordering.** Its first
   home-local attempt failed deterministically at a step no unit or integration suite reaches, and
   produced Sprints `3.36` and `3.37` plus one unowned ledger row — the invalidation Standard P
   predicts, arriving before anything was claimed rather than after.
   **Two structural facts are worth recording for whoever continues it.** First,
   `CodeLocalQualificationStatus` in `src/Prodbox/Test/Qualification/Invite.hs` is a
   **one-constructor type** whose builder ignores its argument, deliberately and with a stated reason
   — so **no command can ever emit `proven`**, and the table below is filled by an operator from run
   evidence rather than by the harness. Second, there is no single entrypoint that runs the
   23-fault × 8-assertion matrix live; `prodbox test all` supplies the canonical-commands, aggregate,
   cleanup/residue, and timestamp columns only.

At this **prior closure checkpoint**, Phases `0`–`2` were reclosed; Sprint `2.36` removed the forced-shutdown path where
`BrokerStopped` could coexist with live internal ownership. Sprint `1.71` replaced independently authored workload
envelopes with derived workload contracts. Earlier Sprints `1.61`–`1.70` remain Done: `1.69` makes
the proof the config **decode gate** (a required
field of `ValidatedSettings` built over the decoded in-force plan, so an over-committed *authored* config
— not just the compiled-in default — is unrepresentable) and `1.70` (✅ Done) wires the
`GuaranteedEnvelope`. Sprint `1.71` derives envelopes from workload proof inputs, and Sprint `3.27`
now derives Kubernetes scheduling admission from those contracts. **`4.52`** consumes the completed
allocation/placement proof against observed host facts. Sprints `3.28`/`3.29` remain Done, and
Sprints `1.72`/`1.73` (✅ Done) build the Ring-1 Dhall over-commit shim (an over-committed `prodbox.dhall`
fails to load through `decodeProjectConfigDhall`) and host-fitting `config generate` (the emitted
`host_capacity` is derived from the observed host, fail-fast when too small; `--portable` for
host-agnostic generation). The doctrine's SSoT is
[resource_scaling_doctrine.md § 2C](../documents/engineering/resource_scaling_doctrine.md); over-commit
is unrepresentable at the Haskell decode gate, the now-built Dhall shim is a defense-in-depth cross-check
one ring ahead of it, and the host is re-proved at reconcile (and pre-fitted at generate). Sprint `2.33` extracts pre-Vault recovery into a minimal Bootstrap Broker and cuts the
pre-Vault scope out of the Gateway Runtime, so every Phase-2 sprint (`2.30`–`2.35`) is Done. Phase
`3` was reclosed on Sprint `3.27`; the later numerical pass also reclosed Phases `4`–`8` on their
then-owned surfaces, with Phase `5` then reclosed on `5.31`. This paragraph is historical evidence,
not the current status ledger; the reopened state is defined in
[Resume Here](#resume-here). Production remained on the
mutually exclusive `LegacyModelBEmitter` pending
Standard P. Sprint `3.26` supplied the chart/render foundations for separate roles but did not
activate the target production topology; remaining activation and removal are plan-tracked.
Sprint `2.35` supplied the prerequisite for the later live-serving validation. Deployment
qualification had not been established on either substrate.

The current gateway-backed lifecycle implementation remains available only as the pre-cutover
baseline. It is scheduled for removal, not extension. The target has one retained Lifecycle
Authority identity, independent substrate-local Target Secret Agents, a minimal Bootstrap Broker,
physically separate Authority Backup/TLS Retention Adapters and fenced Provider Worker, permit-
created Credential Provisioner/External Material Ingress/Admin Action Runner Jobs, a post-export Decommission Runner, and a
mesh/DNS-only Gateway Runtime (with EKS DNS mutation disabled). Vault-root secrets and Model-B
envelope encryption remain valid;
their service ownership and runtime transport change. All earlier completed sprints remain
preserved as historical evidence for their narrower surfaces.

The following baseline facts remain current while the reopened work proceeds; entries explicitly
marked affected are retained only to name their cutover owner:

- `src/Prodbox/Settings.hs` preserves the supported direct `Dhall -> Haskell types` contract by
  decoding the executable-sibling Tier-0 `prodbox.dhall` in-process through the native `dhall`
  library, without
  materializing `prodbox-config.json`.
- `src/Prodbox/BuildSupport.hs`, `src/Prodbox/Repo.hs`, and `test/integration/EnvSuite.hs`
  preserve the operator-facing `.build/prodbox` artifact contract, executable-sibling config-path
  resolution, and the built-frontend env proof for the direct-Dhall settings surface.
- `src/Prodbox/CheckCode.hs` now enforces the governed doctrine-alignment contract described by
  `documents/engineering/code_quality.md`: it fails on repository-owned workflow or git-hook
  surfaces before it runs Fourmolu, HLint, warning-clean Cabal builds, and the operator-binary
  sync step, while excluding generated or retained runtime roots such as `.build/`,
  `dist-newstyle/`, `.prodbox-state/`, and `.data/` from the repo-owned policy scan.
- The supported public surface is Haskell-only. Python source, Python packaging, Python tests,
  Python Pulumi programs, Python type stubs, and Python bridge modules are removed.
- The supported config contract is direct `Dhall -> Haskell types`; `prodbox-config.json` and
  `prodbox config compile` are not part of the supported path.
- **Affected current implementation:** `config setup`, `aws setup`, the native IAM harness,
  long-lived `aws-ses` stack ops, and `prodbox nuke` still acquire the ephemeral elevated credential
  directly through the interactive `SecretRef.Prompt`. The target makes `config setup` Tier-0-only,
  confines prompt ingress to a permit-selected Credential Provisioner/Admin Action Runner or the
  post-export Decommission Runner, and keeps normal Provider work on sealed generations. The
  `aws_admin_for_test_simulation.*` fixture is a test-harness-only `TestPlaintext`
  fixture in `test-secrets.dhall` whose sole purpose is to simulate that operator prompt
  non-interactively; it is never read by a production binary and never stored in
  `prodbox.dhall` or Vault.
- The current suite-level IAM harness still mints one shared operational `aws.*` identity. That
  implementation is explicitly **affected**, not part of the unaffected baseline: Sprints `3.26`,
  `4.49`, `4.50`, `7.33`, and `8.11` replace it with separate Lifecycle-provider, Authority-backup,
  TLS-retention, Gateway-DNS, per-substrate cert-manager-DNS01, and `LongLived` SES-SMTP generations, each with its own
  IAM/Vault/cleanup resource and lifecycle class. The always-run cleanup DAG removes only
  Operational generations after their dependants; LongLived home/backup/TLS/SES-SMTP generations
  and closed non-recoverable-material custody remain.
- `src/Prodbox/TestPlan.hs`, `src/Prodbox/TestRunner.hs`, `src/Prodbox/Prerequisite.hs`, and
  `src/Prodbox/EffectInterpreter.hs` now split the aggregate prerequisite model into an initial
  fail-fast gate plus a deferred cluster-backed backend proof, so `prodbox test integration all`
  and `prodbox test all` no longer fail at `pulumi_logged_in` before the visible `cluster reconcile`
  phase has created or repaired the supported MinIO-backed Pulumi backend.
- The test-only `aws_admin_for_test_simulation.*` fixture remains the sole automation source for
  simulating the admin prompt. In the target it drives one durable setup operation: role-specific
  IAM resources are reconciled, keys are target-sealed and generation-CAS delivered, each exact
  capability is proved, and dependency-ordered revoke/tombstone nodes run on every exit. No
  pre-existing shared credential is a discovery or authorization fallback.
- Supported AWS subprocesses now strip ambient AWS auth and profile variables before projecting
  Vault/Tier-0 credentials into the subprocess environment, so supported paths cannot fall back
  to host AWS auth state.
- The supported container topology lives entirely under `docker/`. Every repository-owned
  Haskell-build Dockerfile stays single-stage `ubuntu:24.04`, installs `ghcup` in-image, pins GHC
  `9.12.4`, and does not create symlinked Haskell tool shims.
- The authoritative local lifecycle target is Haskell-owned and uses a single in-cluster
  `registry:2` backed by MinIO; required public and custom images are present there before later
  Helm deployments proceed.
- The registry publication path retries transient failures on the same candidate and
  then falls through to alternate configured upstreams when publication still fails after manifest
  inspection, with `mirror.gcr.io` fallbacks now covering the Docker Hub-hosted Percona and Envoy
  images used by the supported lifecycle.
- The Haskell-owned lifecycle now retries transient upstream Helm fetch failures during
  `helm repo update` and `helm upgrade --install`, so clean-room restore does not fail terminally
  on intermittent upstream `5xx` or timeout errors.
- `src/Prodbox/CLI/Rke2.hs` now closes the supported lifecycle on native-host-architecture image
  publication only: `amd64` hosts publish `amd64`, `arm64` hosts publish `arm64`, and no
  supported lifecycle path uses `docker buildx` or cross-arch emulation.
- The chart-platform end state is Haskell-owned and renders namespace-local
  Percona-operator-backed Patroni PostgreSQL HA through `src/Prodbox/PostgresPlatform.hs` and
  `src/Prodbox/Lib/ChartPlatform.hs`, with exactly three replicas, synchronous replication,
  deterministic retained PV bindings, retained secret state, and no embedded chart-local
  PostgreSQL subcharts.
- The public `prodbox charts ...` runtime now rejects internal `keycloak-postgres` and `redis`
  dependency releases directly and keeps those names reachable only through their owning root-
  chart orchestration.
- The public `prodbox aws stack ...` surface covers the AWS substrate stacks under
  `pulumi/aws-eks/`, `pulumi/aws-eks-subzone/`, `pulumi/aws-test/`, and `pulumi/aws-ses/`.
  Non-secret validation inputs are synchronized through stack config, while AWS provider
  credentials resolve through Vault/Tier-0 references and the Haskell-owned subprocess environment.
- AWS stack checkpoints use the encrypted Model-B object-store wrapper and are observed through
  authoritative backend outputs. EKS kubeconfig and HA-RKE2 SSH material are bracketed in scoped
  temporary files; no supported stack snapshot, kubeconfig, or SSH-key path persists under
  `.prodbox-state/`. The HA-RKE2 validation may destroy and recreate `aws-test` once when reconcile
  succeeds but SSH validation proves stale instances.
- The pre-cutover gateway runtime surface is Haskell-owned and code-backed in
  `src/Prodbox/Gateway/{Bounds,State,Orders,Peer,Continuity,ContinuityStore,DnsAuthority,ChildSchedule,Daemon}.hs`.
  Bounded Orders admission feeds finite keyed heartbeat/ownership state, signed per-emitter
  cursor/delta/repair exchange, fixed replay/checkpoint/diagnostic retention, and bounded nested
  `/v1/state` cursors. The local-emitter Model-B authority stages and re-observes the exact signed
  assertion/next anchor before publication; its Vault admission marker prevents continuity reset.
  Its remote Model-B continuity and capacity-one child path are superseded on the code-local target
  by Sprint `2.32`'s single-writer identity-bound emitter journal. The default production entrypoint
  remains `LegacyModelBEmitter` until current-revision deployment qualification permits cutover.
  Lifecycle, target-secret, object-store, and
  bootstrap routes leave the gateway under Sprints `2.33`/`4.50`; DNS remains gated by validated
  credential/claim/continuity evidence.
- `prodbox test integration gateway-partition` now runs as a distinct native validation path,
  while the retained peer trust-material fields are validated and bound as authoritative runtime
  transport inputs.
- `src/Prodbox/Tla.hs` still owns `prodbox dev tla-check`, while
  `documents/engineering/tla_modelling_assumptions.md` records the current runtime-to-model
  correspondence and compression points for the Phase `2` surface. Sprint `2.32` completed the
  representative actor/journal/fence refinement with all 16 configured invariants passing; the
  concrete authenticated Orders migration remains native-tested under the model's documented fixed-
  Orders decomposition.
- `src/Prodbox/CLI/Rke2.hs` retains lifecycle-owned bootstrap DNS reconcile and ACME
  `ClusterIssuer` projection; those helpers do not expand the public `prodbox aws stack ...` command
  family.
- `src/Prodbox/CLI/Rke2.hs` now closes the supported lifecycle on the single-binary in-cluster
  `registry:2`, Envoy
  Gateway, cert-manager, and Percona reconcile path with no retained cluster-migration cleanup
  shims for Traefik or the pre-Percona operator surface.
- `src/Prodbox/Infra/AwsTestStack.hs` and `src/Prodbox/Infra/AwsEksTestStack.hs` now sync only
  the supported retained AWS-validation stack inputs and no longer remove older Pulumi
  provider-key layouts on the supported path.
- The self-managed public edge now installs Envoy Gateway, renders Gateway API resources, and
  protects shared-host browser, API, WebSocket, and admin routes through Envoy auth policy.
- `src/Prodbox/CLI/Rke2.hs` now renders config-selected MetalLB L2 or BGP resources, lifts the
  Envoy Gateway controller and data-plane replica counts into settings, and builds or imports the
  single union runtime image (`prodbox-runtime`, shared by the gateway daemon and the api/websocket
  workloads) during `cluster reconcile`.
- The supported public-edge auth doctrine now makes the carrier and key-discovery boundary
  explicit: JWT-only API routes validate request-carried bearer tokens locally at Envoy from
  Keycloak issuer metadata plus JWKS-backed signing keys, Envoy-managed browser auth returns
  through the edge redirect and cookie or session path, and direct-OIDC workloads keep their
  carrier or session state workload-owned.
- Keycloak availability now stays explicit in the plan: it is required for new logins, refresh
  flows, and later JWKS refresh, but the steady-state JWT request path does not synchronously call
  Keycloak or Redis while Envoy still has cached signing keys and the presented tokens remain
  valid.
- The current supported transport boundary now stays explicit in the plan: public TLS terminates at
  Envoy for the shipped `/vscode`, `/api`, and `/ws` routes on
  `test.resolvefintech.com`, while backend TLS or mTLS is outside the supported
  chart-workload contract unless a later doctrine revision expands that path.
- `src/Prodbox/PublicEdge.hs` now centralizes the shared-host route catalog and issuer derivation
  consumed by lifecycle, DNS, chart, host-diagnostic, and native validation surfaces, keeping
  `/auth`, `/vscode`, `/api`, `/ws`, and `/minio` aligned on one Haskell-owned
  public-edge contract.
- Root `README.md` plus governed doctrine describe the public route catalog and the target
  lifecycle-control-plane split. Sprints `1.60`, `2.31`, `3.25`, `4.47`, `5.16`, `5.17`, and
  `8.10` remain completed historical corrections; the current production-composition
  counterexample expands their owning phases through Sprints `1.61`–`8.12`.
- `charts/keycloak/`, `charts/api/`, `charts/redis/`, `charts/websocket/`, `charts/vscode/`,
  `src/Prodbox/Lib/ChartPlatform.hs`, and `src/Prodbox/Workload.hs` now own the shared-host
  workload contract, including the internal `workload.mode = Api \| Websocket` runtime selector
  sourced only from the mounted Dhall config per
  [config_doctrine.md](../documents/engineering/config_doctrine.md) (Sprint `3.14` removed the
  legacy environment selector),
  JWT-only API delivery, Redis-backed shared-state continuity on the WebSocket route, workload-
  managed OIDC bootstrap, real `/ws` upgrade handling, and settings-backed workload scaling.
- The current WebSocket doctrine now states that one upgraded connection remains pinned to one
  selected backend pod until disconnect, reconnect-safe state must live outside the pod, and the
  implemented runtime now closes on readiness-based drain plus revocation-driven reconnect
  behavior on the real `/ws` path.
- Redis now stays explicit as shared application state for the current WebSocket surface and any
  later explicit external rate-limit service, but the current supported worktree still does not
  ship a standalone rate-limit-service workload or validation path.
- `src/Prodbox/Host.hs` and `src/Prodbox/TestValidation.hs` now classify and validate the
  current Keycloak identity, `vscode`, `api`, `websocket`, and MinIO routes through named
  external validations on one shared hostname.
- `src/Prodbox/Host.hs` now recognizes only the supported
  `System clock synchronized` timedatectl field in `parseTimedatectlNtpDisposition`, so the
  Phase `2` host-info path closes on the Ubuntu 24.04 field format described by the current
  doctrine.
- `charts/gateway/` and `prodbox gateway start|status|config-gen` remain the separate Haskell
  distributed gateway daemon surface; they are not the Envoy Gateway public edge.
- The canonical validation surfaces are `prodbox dev check`, `prodbox test unit`,
  `prodbox test integration cli`, `prodbox test integration env`, the named Haskell-owned
  validation
  flows in `src/Prodbox/TestValidation.hs`, and the aggregate reruns
  `prodbox test integration all` plus `prodbox test all`.
- The aggregate rerun contract is owned by the shared suite plan behind
  `prodbox test integration all` and `prodbox test all`, including AWS IAM,
  Route 53, public-edge, EKS, HA-RKE2, destructive lifecycle, and post-test restore.
- Phase `6` is reopened on Sprint `6.4` because the current aggregate demonstrated that the
  postflight restore path can skip independent local restoration after a retained-resource
  failure. It recloses only on current-revision cutover and cleanup qualification.
- [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md) is the sole cleanup ledger.
  The Sprint `2.31` log/transport, Sprint `3.25` probe, Sprint `4.47` retained-lifecycle, Sprint
  `5.16` stability, Sprint `5.17` assumed-pre-existing/manual-preparation, and Sprint `8.10`
  exit-code-only SES-readiness removals remain under `Completed` as historical work. New rows own
  the arbitrary readiness action, subprocess object store, shared child queue, gateway authority,
  synchronous SES bracket, selected-target-only SMTP/EAB materialization, Pulumi-owned SMTP
  identity, fail-fast restore, and memory-only stability residue. Sprints `7.33` and `8.11` are the
  single removal owners for the custody cutover and credential-ownership migration respectively;
  prior completed rows are not revived.

### Foundation Epoch

Counterexample `LCPC-2026-07-11` froze four failure mechanisms that live at cross-artifact seams
(Haskell ↔ chart YAML ↔ kubelet, authored numbers ↔ physics, chart-lifetime storage ↔ retained
state, list position ↔ dependency structure) rather than inside one compiled program. Governance
Sprint `0.17` adopts the corrective doctrine — one typed model, many generated projections — and
registers the structural owners:

- Sprint `2.34` makes hand-authored daemon route, probe, and chart-identity literals
  unrepresentable behind one compiled route registry and chart statics, and makes readiness one
  pure projection over cached boundary-owned facts. ✅
  **Done**: the closed `GatewayRoute` registry, total daemon dispatch, client/probe/wire-path
  projections, readiness projection, chart statics, generated sections, and forbidden-literal lint
  are landed and validated. Sprint `2.32` completed the code-local target topology's emitter-
  authority refinement to a current journal-lock/Lease/recovery witness; the production rollback
  latch remains selected pending deployment qualification.
- Sprint `4.51` makes retained SES authority state stored through a chart-lifetime transport a
  type error via durability-indexed coordinates and adapters, with a host-direct retained store
  and idempotent operation records.
- Sprint `5.20` derives restore/cleanup edges from registered chart-dependency and
  storage-lifetime facts and replaces the fail-fast fold with a total aggregate-report executor,
  so a sibling failure can never silently discard independent restoration.
- Sprints `1.65` and `5.21` make authored Guaranteed-QoS envelopes measured rather than asserted:
  committed measured-profile artifacts certify authored CPU headroom, throttle exposure, and
  staleness inside the canonical quality gate. Sprint `1.65` ✅ **Done**: the
  `MeasuredResourceProfile` type, the CPU-headroom / memory-high-water / throttle-ppm / staleness
  certification rules, and the conformance-tier wiring land (inert until `5.21` commits the first
  profile), plus the operator-approved interim gateway 750m envelope with a vscode-quota rebalance.
- Sprints `1.68`/`1.72`/`1.73`/`3.27`/`4.52` make cluster/host resource over-commitment **unrepresentable**: the
  `host ≥ cluster ≥ Σworkloads` nesting moves into an opaque proof-carrying `AllocatedResourcePlan`
  (total `compileResourcePlan`, matching `ServiceCapacityPlan`/`RuntimeMemoryPlan`) with a
  non-saturating budget subtraction, namespace quotas **derived** from workload draws, `cluster ≤ host`
  closed at reconcile against **observed** facts, a `GuaranteedEnvelope` witness, and a `dev check`
  gate that fails the build if `defaultResourcePlan` over-commits. Memory-(c) is already structural via
  `RuntimeMemoryPlan`; CPU demand-(c) stays the non-erasable `uncertified-until-first-profile` seam
  above. Sprint `1.68` ✅ **Done** (the opaque proof + gate landed in `src/Prodbox/Capacity/Allocation.hs`,
  `dev check` exit 0, 18/18 `test/unit/Allocation.hs`); its consumers `3.27` and `4.52` are ✅ **Done**.
  Sprints `1.72`/`1.73` ✅ **Done** add the defense-in-depth Ring-1 layer: the generated `prodbox.dhall`
  carries a baked-in over-commit `assert` (an over-committed hand-edit fails to load, one ring ahead of
  the decode gate) and `config generate` derives a host-fitting `host_capacity` from the observed host,
  failing fast when the host is too small (`--portable` for host-agnostic generation). Motivated by a
  live gateway CPU-throttle counterexample that passed every capacity validation yet still failed at
  runtime, and by a live deploy blocked by a fixed 280 GiB default `host_capacity` on a 238 GiB host.
- Sprints `1.64` and `1.66` remove the gateway hot-path CPU drivers (per-call TLS manager,
  per-request Vault login, subprocess object store) behind a shared manager, a cached
  single-flight Vault session, and a native SigV4 client. Both ✅ **Done**: Sprint `1.64` landed the
  shared `sharedTlsManager` singleton and the cached renewable `Prodbox.Vault.Session`
  (single-flight renewal at two-thirds TTL, sealed/revoked classification, one `403`
  invalidate-and-relogin); Sprint `1.66` landed the byte-exact `Prodbox.Aws.SigV4` and the native
  in-memory `Prodbox.Minio.ObjectStoreNative` over the shared manager, with the subprocess path kept
  as the config-selectable rollback until live-MinIO parity is proven.
- Sprint `1.63` ✅ **Done** — derives the conformance tier (`runConformanceTier`) and the
  machine-readable legacy escape registry (`src/Prodbox/Legacy/EscapeRegistry.hs`) so cross-artifact
  drift and unregistered escape call sites fail `prodbox dev check` in seconds (the Standard P
  interim escape-path guard). Eight escape seams were registered and bijectively marked at that
  historical closure. The current registry has since shrunk to one declared site; the 2026-08-15
  audit found that known Pending compatibility seams are unmarked, so Sprint `4.84` owns
  comprehensive inventory coverage rather than treating the one-entry bijection as absence proof.
- Sprint `7.34` narrows the harness postflight residue bypass back to per-run, restoring the
  long-lived aws-ses/public-edge-tls protection of the lifecycle preconditions.

Foundation Epoch Sprints `1.63`–`1.66`, `2.34`, `4.51`, `5.20`, `5.21`, and `7.34` are Done; Sprint `1.68` is ✅ Done (own-surface Phase-1 reopen, now
reclosed) and its Phase-3/4 consumers `3.27`/`4.52` are ✅ Done. Sprints `1.61` and `1.62` are Done, and
Sprint `1.67` recloses their phase after removing the substrate-specific prerequisite edge. The
[Deployment Qualification](#deployment-qualification) ledger is unchanged by this adoption: both
substrate rows remain **pending**, and nothing in the epoch claims qualification.

## Exit Definition

This plan is complete only when all of the following are true:

1. `DEVELOPMENT_PLAN/` and governed doctrine describe the Haskell architecture and the Envoy
   Gateway target rather than the retired Python architecture or a Traefik end state.
2. The supported operator flow is `prodbox`, implemented in Haskell, across config, lifecycle,
   AWS stack orchestration, gateway, chart delivery, validation, and AWS administration.
3. The supported config contract is direct `Dhall -> Haskell types` from the executable-sibling
   Tier-0 `prodbox.dhall`, with `prodbox-config-types.dhall` aligned to the
   decoder and no generated `prodbox-config.json` artifact or supported `prodbox config compile`
   path.
4. Public `prodbox config setup` authors/validates Tier-0 coordinates only. Cluster genesis and
   public `prodbox aws ...` identity paths can bootstrap all required AWS credentials from scratch
   through a mode-indexed, attested Credential Provisioner, with separate Lifecycle-provider,
   Authority-backup, TLS-retention, Gateway-DNS, per-substrate cert-manager-DNS01, and deterministic
   `LongLived` SES-SMTP IAM/Vault generations and no shared runtime key. The SES SMTP identity is
   never a Pulumi/Provider-Worker resource; the Provisioner derives its region-bound SMTP payload
   before the retained-home Agent Transit-seals it. ACME EAB uses a distinct schema-indexed External
   Material Ingress/permit and cannot reuse the bounded first-reconcile AWS-admin identity session;
   both payload kinds use closed retained-home custody/attested rewrap, never generic export.
5. `aws_admin_for_test_simulation.*` lives only in the test-harness-only `test-secrets.dhall`
   (`TestPlaintext`), never in `prodbox.dhall` or Vault, and its sole purpose is to
   simulate the operator's interactive admin-credential prompt for suite-driven credential/admin
   validation and exported-manifest `prodbox nuke`. Prompt bytes enter only the attested
   permit-selected Credential Provisioner/Admin Action Runner or, after Authority permanent stop,
   the manifest-constrained Decommission Runner; `config setup`, normal provider work, and
   long-lived controllers never receive them. There is no production config-backed admin path.
6. `prodbox test integration aws-iam`, targeted
   `prodbox test integration <name> --substrate aws` validations,
   `prodbox test integration all`, and `prodbox test all` share one joint idempotent IAM
   validation harness that submits the same durable setup operation as the public flow, seals and
   generation-CAS delivers each role-specific key, proves every exact identity/capability pairing,
   registers cleanup before mutation, destroys validation-owned per-run/Operational resources, and
   deletes each such IAM/key resource before committing its Vault tombstone. No pre-existing shared
   credential is a discovery or authorization fallback; LongLived backup/TLS/home-DNS/SES-SMTP
   identities and closed custody receipts are instead proven retained and readable by only their
   exact consumer.
7. The operator-facing binary lives at `.build/prodbox`, produced by the canonical
   `cabal build --builddir=.build exe:prodbox` invocation plus a copy step.
8. Container-side build artifacts live under `/opt/build`, and every repository-owned Dockerfile
   lives under `docker/`.
9. Every repository-owned Haskell-build Dockerfile is single-stage from `ubuntu:24.04`, installs
   `ghcup` in-image, pins GHC `9.12.4`, and does not create symlinked Haskell tool shims; no
   supported browser-facing auth path depends on a repository-owned nginx auth-proxy image.
10. `prodbox.cabal`, `cabal.project`, and the canonical build-and-test surfaces are explicitly
    upgraded for GHC `9.12.4`, including any required cabal-bound changes and full canonical
    validation reruns on that toolchain.
11. `prodbox dev check` enforces the governed doctrine-alignment contract described by
    `documents/engineering/code_quality.md`, not only formatter, linter, build, and binary-sync
    checks.
12. The Haskell distributed gateway runtime, `gateway status` client path, and daemon config
    validation close only when `/v1/state` is bounded independently of uptime, the dedicated
    `/healthz` and `/readyz` projections remain constant-time, the Orders-backed interval
    relationships are preserved, and the runtime/model correspondence records the finite semantic
    projection and delta protocol.
13. The self-managed public edge uses MetalLB, Envoy Gateway, Kubernetes Gateway API, and
    cert-manager rather than Traefik plus `Ingress`.
14. Every externally reachable application or operational dashboard routes through Envoy on the
    single canonical hostname `test.resolvefintech.com`, using explicit path prefixes such as
    `/vscode`, `/api`, `/ws`, `/auth`, and later supported admin paths.
15. The supported public-edge doctrine uses exactly one public DNS entry, one listener
    certificate, and no dedicated identity, browser, API, or WebSocket hostnames. Wildcard
    public DNS is unsupported.
16. `prodbox edge status`, `prodbox test integration charts-vscode`,
    `prodbox test integration charts-api`, `prodbox test integration charts-websocket`, and the
    named admin-route validations close on Gateway, `HTTPRoute`, auth policy, certificate, and
    one Route 53 record rather than `IngressClass`, `Ingress`, or per-FQDN state.
17. Supported config, onboarding, and lifecycle surfaces remove `example.com` entirely and do not
    accept or emit placeholder public domains. The rule is scoped to **runtime** surfaces — what
    the binary accepts as configuration and emits as live records. It does **not** reach
    documentation examples or test fixtures, which under
    [vault_doctrine.md §20.1](../documents/engineering/vault_doctrine.md#201-the-rule) must
    *prefer* reserved domains. The two rules govern the same names in opposite places: a reserved
    name must never reach a served host or a real DNS record, and is exactly what a doc example or
    a simulated response should use.
18. MetalLB supports both the L2 implementation path and a config-selected BGP implementation path
    on the supported self-managed cluster surface.
19. Envoy validates Keycloak-issued JWTs locally and applies route-level RBAC for application and
    admin routes. Issuer, audience, path-claim requirements, bearer-token carriers, browser
    return paths, and JWKS discovery or refresh ownership remain explicit.
20. Redis appears only as repo-owned app-level shared state for supported realtime or rate-limit
    workloads; it is never part of Envoy JWT validation, and the current supported worktree does
    not yet ship a standalone external rate-limit-service surface.
21. Supported WebSocket workloads authenticate at connection setup on the shared-host `/ws`
    route, keep reconnect-safe state outside the pod, keep each live upgraded connection pinned
    to one backend pod until disconnect, define token-expiry and authorization-change behavior
    explicitly, leave per-message authorization to the workload when messages need finer-grained
    permissions than the edge can enforce, scale horizontally behind Envoy, use readiness-based
    drain before pod exit, and add named validations for reconnect, connection-pinning,
    token-expiry handling, authorization-change assumptions, readiness-based drain,
    per-message authorization ownership, and shared-state assumptions.
22. Keycloak-backed public workloads stay proxy-aware behind Envoy on the shared hostname rather
    than on a dedicated identity host. Keycloak availability gates login, refresh, and later
    JWKS refresh, while cached signing keys and unexpired tokens keep the steady-state JWT hot
    path local to Envoy.
23. Public TLS terminates at Envoy on the supported path, and one certificate covers
    `test.resolvefintech.com`. Backend TLS or mTLS is not part of the current supported workload
    contract unless a later doctrine revision makes that backend transport explicit.
24. Direct public-registry pulls are permitted only for the bounded MinIO/storage dependencies
    needed to bootstrap the in-cluster `registry:2` service.
25. Every later supported Helm deployment obtains its images from that in-cluster registry.
26. `prodbox` idempotently ensures required public images and all custom images are present in
    the registry before those later deployments.
27. Supported custom-image builds and registry publication use only the native architecture of the
    machine running `prodbox`: `amd64` hosts build and publish `amd64` images, and `arm64` hosts
    build and publish `arm64` images.
28. Native `arm64` publication works on native `arm64` Docker daemons. `docker buildx`,
    cross-arch emulation, and mixed-arch cluster closure are not part of the supported lifecycle
    or chart-delivery path.
29. Every supported Helm-managed PostgreSQL deployment is external, reconciled only through the
    cluster-wide Percona operator, and runs Patroni HA with exactly three PostgreSQL replicas,
    synchronous replication, and no embedded chart-local PostgreSQL subchart.
30. Pulumi remains part of the supported architecture for true IaC and AWS substrate resources.
    The public `prodbox aws stack ...` surface stays limited to those stacks, while local-cluster
    lifecycle, bootstrap DNS reconcile, and ACME `ClusterIssuer` projection remain owned by
    `src/Prodbox/CLI/Rke2.hs` rather than by a public Pulumi operator flow.
31. No supported Pulumi program depends on Python.
32. Two consecutive strongest clean-room reruns pass on each supported substrate from destructive
    setup through final cleanup using the Haskell stack and the exact authored resource envelopes.
33. Every `Pending Removal` row in
    [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md) is either removed with its
    replacement verified or moved to `Completed`; no unsupported compatibility surface remains at
    plan exit.
34. The repository has no supported-path Python implementation or Python toolchain ownership
    artifacts left.
35. The Haskell gateway daemon materializes peer transport from the certificate, key, CA, and
    socket fields already retained in `DaemonConfig` and `Orders`: every node updates
    `stateLastHeartbeatTimes` from inbound peer events rather than from the local heartbeat loop
    only; finite latest-heartbeat/ownership state converges through signed per-emitter monotonic
    sequences, per-emitter previous hashes, vector-cursor deltas, and bounded signed compaction
    checkpoints; and `/v1/state` exposes bounded per-peer transport health for operator inspection.
36. The home-substrate gateway daemon emits signed `Claim` and `Yield` evidence on owner
    transitions and gates its registered home Route 53 A-record writes on a credential-ready
    runtime equivalent of the modelled `CanWriteDns`
    predicate, so `ClaimPrecedesWrite` and `YieldPrecedesReclaim` hold on the bounded semantic
    event projection rather than only on the model, ambient AWS authentication cannot create write
    authority, and a stale owner cannot reclaim without observing its yield superseded by a fresh
    claim. The EKS Gateway DNS mutation capability is disabled; the AWS A record is owned by the
    exact Lifecycle Authority provider intent required by item 51.
37. The supported-host gate fails fast when the host's NTP synchronization state is unhealthy, the
    gateway daemon records the maximum observed inter-node clock skew on `/v1/state` and refuses
    inbound heartbeats whose timestamps exceed the documented bound, and the architecture and TLA+
    correspondence docs name that bound, the operator response, and how the model's bounded-delay
    assumption maps to a runtime-enforced skew limit.
38. Orders documents carry a monotonic version field, daemons reject inbound peer evidence from a
    peer presenting an older Orders version, a new Orders version propagates through bounded delta
    gossip and is adopted by every live daemon before the next election tick, and a daemon
    rebooting against a stale Orders version refuses to claim ownership until its Orders view
    catches up.
39. Invite-capable suite plans submit an idempotent durable operation to the retained Lifecycle
    Authority. Provider mutation, exact-revision semantic readiness, SMTP generation, and
    per-target delivery are journaled and resumable; only mutation stages hold narrow fences, and
    target delivery proceeds through the selected substrate's Target Secret Agent outbox. Pulumi
    owns only non-credential SES resources. The deterministic `LongLived` SMTP identity belongs to
    the `OperatorMaterialPermit`-selected Credential Provisioner, and retained-home schema-bound
    custody restores the same generation into a fresh AWS Vault without prompt or key rotation.
40. Runtime stability is proved by a run-wide temporal fold over restart/OOM/memory, CPU
    throttling, queue occupancy/wait, admission refusal, p95/p99 operation latency, cancellation,
    and deadline-miss evidence. Point readiness never erases an earlier unhealthy observation.
41. Bootstrap Broker, Lifecycle Authority, Target Secret Agent, Gateway Runtime, Authority Backup
    Adapter, TLS Retention Adapter, and fenced Provider Worker are physically separate workloads
    with distinct identities, policies, Services, resource envelopes, queues, and failure domains.
    Credential Provisioner/External Material Ingress/Admin Action Runner Jobs are mode/schema/permit
    isolated, the bounded first-reconcile AWS-admin session covers identity permits only, and the
    Decommission Runner exists only after Authority export and stop. The ordinary teardown recovery
    projection derives its minimal subset from this same graph and owns a bootstrap-core external
    caller identity whose lifetime is independent of Gateway and application charts.
42. The component graph requires operation-indexed capabilities. Observation, admission, and
    execution use the same opaque reference; no arbitrary injected `IO` action or differently supplied
    endpoint can satisfy a dependency edge.
43. Every supported control-plane request carries one absolute deadline across queueing,
    credential refresh, external I/O, read-back, cancellation, and response. Saturation refuses
    immediately and retries never extend that deadline.
44. Each gateway emitter has one actor and one encrypted identity-bound retained journal. The actor
    owns the complete stage/fsync/publish/commit/fsync transition; no competing continuity loop or
    shared lifecycle queue can interleave it.
45. A pure lifecycle-indexed registry makes `LongLived` cascade targets unconstructible. It has
    distinct test-scoped `PerRun` and production-retained `LongLived` EBS keys selected before
    provider observation; runtime tags can validate the selected identity but cannot mint or change
    its lifecycle class. Exact-resource observations are complete by registered key, coordinate,
    authority, revision, and durable-run scope; checkpoint-copy and ownership-manifest observations
    retain their distinct stack/copy or manifest provenance under that scope; aggregate escape-
    audit observations carry only their surface-indexed query/registry/run scope and cannot become
    keyed resource evidence.
    `Partial`/`Unobservable` are explicit facts that select typed refusal, never absence. The
    lifecycle core, not the suite, owns the durable always-run graph, stable operation IDs, and
    report; `TestRunner` is a client. Pre-manifest AWS recovery admits only a bounded
    admin-confirmed plan whose exact digest is receipt-committed and independently read back; broad
    discovery, ambiguity, or unobservability cannot construct its adoption manifest. Sibling failure
    cannot suppress independent or
    `RequiresAttempt` work, and the result retains the original and every cleanup failure.
    `ReadyToUninstallEvidence` is private and requires exact per-run/family absence, complete
    credential disposition, the exact intended-retained set with zero unexpected resources, a
    backed-up/read-back pre-uninstall report, and a one-shot permit. `CascadeCompleteEvidence`
    additionally requires exact `LocalUninstallEvidence` and the matching read-back
    `LocalCompletionReceipt`; all witnesses bind one `CleanupRunId`, registry revision, account,
    region, substrate, operation scope, and report digest. Incomplete results carry an honest
    `RecoveryPlaneDisposition` (`Established`, `NotEstablished`, or `Lost`).
46. Teardown cutover uses a private GADT-indexed pre/post-activation state and exactly one logical
    writer. Only pre-activation state can construct legacy rollback; activation consumes current-
    revision `QualificationPassed` evidence and the legacy-writer permit, then yields the sole
    replacement-writer permit, with no post-activation
    legacy rollback or dual-writer inhabitant. The public generic/home route is activated and its
    legacy path removed under Sprint `6.5`; exact AWS adapters and checkpoint-derived EKS-access
    removal are independently completed under Sprint `7.36`. Every residual stays Pending Removal
    until its replacement is the sole supported route and current qualification passes.
47. The Deployment Qualification table is `proven` for the exact current secret-safe
    `SourceIdentity` and generated-config identity on both substrates, including the recorded and
    hashed source-manifest exclusion-policy/version and the required load/fault/cancellation/
    response-loss and cleanup campaign. Historical runs or pending live evidence cannot satisfy
    this exit condition.
48. `LCPC-2026-07-11` retains the frozen expected superseded-composition failure and replacement
    pass under identical topology-normalized total budget/load, plus the replacement's separate
    production-envelope profile, with separate complete source/config/image/wiring identities and
    evidence digests. Public evidence contains only opaque Authority receipt/generation IDs or
    Vault-keyed HMAC commitments for secret-dependent inputs; it never hashes plaintext secrets.
    Since Sprint `5.32` ✅ (2026-08-11) the *retained* half is a repository-owned record rather than
    a regenerated constant: `test/qualification/LCPC-2026-07-11.dispositions` holds the per-mechanism
    expected failure and replacement pass, bound into the trace digest, and the mutation fixture
    beside it proves the reproducer can fail. This condition still requires the qualification run;
    what changed is that a green result from the reproducer is now evidence.
    `TEARDOWN-2026-08-15` separately retains the exact operator trace, mutation-sensitive old/new
    dispositions, and complete fault matrix. Its causal profile holds background load, ordered
    fault schedule, and topology-normalized total CPU, memory, ephemeral storage, and persistence
    constant; records every exact old→new envelope mapping, expected superseded failure, and
    replacement-reference pass; and keeps the independently justified rendered production profile
    separate. Sprint `5.35` must add the target repository inputs under
    `test/qualification/TEARDOWN-2026-08-15.*`; they do not exist in the current tree. Once landed, a
    reference-oracle pass may correctly expect `CascadeIncomplete` when the independent
    caller-observation failure remains, and cannot be narrated as cascade success.
49. Lifecycle Authority alone owns the in-force config generation/reference; every component uses a
    role-scoped projection, and no host/Gateway/direct-MinIO config path remains.
50. Lifecycle-provider, Authority-backup, TLS-retention, Gateway-DNS, per-substrate
    cert-manager-DNS01, and SES-SMTP identities are distinct IAM/Vault generations with no shared key
    or cross-role fallback. Operational Lifecycle-provider/AWS-run DNS01 identities follow dependency
    cleanup; LongLived SES-SMTP is retained by ordinary postflight and removed only by
    `DestroyAwsSes`/the equivalent nuke node after consumers quiesce and the Provider Worker reads
    back provider-stack absence. The Admin Action Runner deletes/reads back external IAM before live
    Agents tombstone target generations and retained-
    home custody, with all failures aggregated. LongLived backup is deleted only by external-receipt
    `nuke`; TLS-retention and home Gateway-DNS/home-DNS01 may also leave through explicit consumer
    decommission after their exact dependants are absent. In `nuke`, every consumer/prefix is absent
    and the shared bucket is last.
51. Every prodbox-created Route 53 record is registered by exact account/zone/name/type/owner epoch
    and has typed observe/ensure/delete/read-back through its sole owner.
52. Root and child Vault initialization encrypts the initial root token to a pinned/audited burn
    public key whose private material existed only inside an isolated destructive ceremony, was
    never exported, was destroyed before adoption, is never accepted, retained, or available to
    prodbox, and has no known holder; prodbox never decrypts or uses the initial token. Encrypted recovery-share receipts are durably acknowledged before
    baseline; separately generated short-lived root sessions are inventoried by non-secret
    accessor, revoked after read-back, and observed absent. No usable initial token or plaintext
    recovery share appears in unlock-bundle token fields, parent custody, config, authority state,
    logs, or fixtures.
