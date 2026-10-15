# TLA+ Modelling Assumptions

**Status**: Authoritative source
**Supersedes**: N/A
**Generated sections**: none

> **Purpose**: Define the registered models' runtime correspondence — the gateway emitter's finite
> actor, journal, fencing, acknowledgement, checkpoint and pre-cutover liveness domains, and the
> lifecycle create's ownership ordering — as explored by TLC, and the boundary between formal safety
> evidence and native/runtime proof.

---

## 0A. Planning Ownership

This document owns modelling assumptions, implementation correspondence, and verification limits.
Sprint status, deployment qualification, and remaining work are owned by
[DEVELOPMENT_PLAN/README.md](../../DEVELOPMENT_PLAN/README.md).

The formal entrypoint is `prodbox dev tla-check`. The separate native
`prodbox test integration gateway-partition` path validates runtime behaviour and does not delegate
to TLC.

---

## 1. Modelled System

The target specification is
[`documents/engineering/tla/gateway_orders_rule.tla`](./tla/gateway_orders_rule.tla). The completed
Sprint `2.32` refinement adds one representative per-emitter single-writer actor, one real peer
boundary, an explicit two-barrier journal protocol, and the incarnation/Lease fences that admit a
writer to the bounded semantic gateway model. The separate pre-cutover specification is
[`documents/engineering/tla/gateway_legacy_liveness.tla`](./tla/gateway_legacy_liveness.tla); it
models the temporary remote-Model-B topology's durable process-boot and periodic backend-proof
fences, compacted-cursor boot witness, and signed latest-only liveness protocol without inserting
that adapter into the target actor model.

The third specification is
[`documents/engineering/tla/lifecycle_create_ownership.tla`](./tla/lifecycle_create_ownership.tla),
added by Sprint `5.48`. It is not about the gateway. It models the ordering of durable writes around
a provider effect — admit, commit generation, commit and read back a write-ahead ownership manifest,
dispatch, land, append, settle — together with the two ways the host can stop knowing what it did: a
transport deadline that cancels the reply, and a crash. § 1.6 owns it.

There is deliberately no append-only event log. Each emitter has fixed slots for:

1. one committed journal record and at most one unsigned transition plan or exact staged record
2. one scalar transition-owner incarnation, one active transition-admission ticket, one
   exact-record ticket, one next-ticket counter, and one deadline-open bit
3. one running-incarnation set, one OS journal-lock holder, one fsynced incarnation, and one Lease
   holder
4. one semantic checkpoint per viewer/emitter pair
5. one overwriteable pending frame per directed viewer/emitter pair
6. one acknowledgement projection per emitter/peer pair
7. one signed repair-floor checkpoint per emitter

The model therefore represents the production cardinality bound directly. Time, repeated
heartbeats, crash/restart cycles, and unreachable peers change values inside these slots; they do
not allocate new slots.

### 1.1 Single-writer actor and fencing

`running[n]` may contain both incarnation `1` and incarnation `2`, so TLC exercises an overlapping
replacement Pod while the previous process is still alive. Overlap does not grant authority.
`Fenced(n, incarnation)` holds only when the same incarnation:

- is running
- owns the exclusive OS journal lock
- equals the monotonically fsynced journal incarnation
- equals the identity-bound Kubernetes Lease holder

`StartActor`, `AcquireJournalLock`, `FsyncIncarnation`, and `AcquireLease` make that order explicit.
The journal's `transitionOwner` is one scalar rather than a set, and every journal mutation requires
the complete fence. `ExpireLease` immediately removes the transition owner, closes any retained
deadline, and rewinds the journal to its last durable state. `CrashActor` additionally releases the
OS lock, allowing the greater incarnation to acquire it. A stale process may remain in `running`;
it cannot take a transition.

The concrete Lease holder identity binds emitter identity, incarnation, journal digest, and
journal-identity digest. TLC represents the cryptographic digests as a constant identity and models
the incarnation equality that controls mutation. Hash collision resistance and Kubernetes
resource-version/CAS encoding are native-test obligations.

### 1.2 Admission identity, deadlines, and exact journal protocol

`nextAdmission` is the bounded abstraction of `Emitter.Kernel`'s monotonic `Word64` admission
counter. `BeginAssertion` and `BeginEpochCheckpoint` consume that counter exactly once, install the
ticket as `activeAdmission`, and enter `staging` with an unsigned transition plan. The counter never
wraps or reuses a ticket. `CompleteStage` accepts only the active ticket and binds the resulting
exact immutable record to `stagedAdmission`. Every later completion supplies both its transition
ticket and its exact-record ticket; `ExactCompletionFenced` requires both to equal the active
transition before a phase can move.

`RejectDelayedCompletion` makes the rejected path observable. It can deliver an older ticket to a
same-incarnation newer transition, or name the current ticket while carrying the exact record from
an older transition. The action records the mismatched identities but changes no phase, staged
record, publication witness, or committed anchor. Thus process-incarnation equality alone is not a
completion fence.

`deadlineOpen` is a bounded state abstraction of the in-flight absolute deadline. Every successful
completion through publish requires it to be open. `ExpireAdmission` discards an unsigned
`staging` plan; a later begin obtains a separately numbered admission. Once exact staged bytes
exist, expiry retains the record and admission but closes the deadline, so no phase can advance
until `RecoverAdmission` installs a fresh open recovery deadline. Crash or Lease loss similarly
closes a retained durable stage before `ResumeDurableStage` and recovery.

The `journal.phase` values correspond to six separate effects:

| TLA+ action | Resulting phase | Runtime effect |
|---|---|---|
| `BeginAssertion` / `BeginEpochCheckpoint` | `staging` | consume a monotonic transition admission and issue signing for the unsigned plan |
| `CompleteStage` | `stageWritten` | accept the ticket-matched exact signed staged record, not yet durable |
| `FsyncStage` | `stageDurable` | complete the first file-and-directory durability barrier |
| `PublishStaged` | `published` | publish only the exact durable staged record and fill bounded peer slots |
| `WriteCommit` | `commitWritten` | write the committed projection, not yet durable |
| `FsyncCommit` | `idle` | complete the final durability barrier, advance the committed anchor, and clear the stage |

The crash mapping is explicit:

| Crash/Lease-loss point | Retained journal after restart | Required recovery |
|---|---|---|
| `idle` | committed record | recover the bounded semantic projection |
| `staging` | committed record; unsigned plan is absent | begin again under a separately numbered admission |
| `stageWritten` | committed record; un-fsynced stage is absent | stage again |
| `stageDurable` | exact durable stage | resume at publish |
| `published` | exact durable stage | idempotently republish, then commit |
| `commitWritten` | exact durable stage | idempotently republish and rewrite commit, then final fsync |

Thus every signed phase that survives the journal durability boundary is logically rewound to
`stageDurable`, clears any volatile publication witness, and republishes the same exact record
before commit and the final fsync. The concrete kernel applies the same normalization to every
signed phase present in a valid decoded durable projection, beginning again with `EffFsyncStage`;
an actual process restart selects the last authenticated fsynced journal generation. Neither model
nor runtime recovery generates replacement signed bytes.

`ResumeDurableStage` may transfer actor ownership to a greater incarnation but does not alter the
staged assertion's admission, incarnation, bytes, anchor, Orders identity, or semantic kind. This
models exact replay rather than regeneration after a crash. `RecoverAdmission` refreshes only the
deadline. A subsequent newly staged assertion carries the new fsynced incarnation and a new
admission. Peers can therefore accept an idempotent older-incarnation replay at its existing
position while rejecting any transition whose incarnation/position regresses.

An ordinary staged assertion advances sequence without wrapping. Sequence exhaustion permits only
an epoch checkpoint at sequence zero in the next non-exhausted epoch. When both finite domains are
exhausted, no further emission action exists.

### 1.3 Bounded acknowledgement and checkpoint state

`pending[receiver][emitter]` is one overwriteable directed frame slot. It carries incarnation,
Orders version, epoch, sequence, and semantic kind. `DeliverAndAcknowledge` accepts only an immediate
non-regressing successor under the receiver's current Orders identity, updates one semantic slot,
and advances one fixed acknowledgement slot. Duplicate, delayed, and wrong-Orders frames are
discarded without moving semantic state.

`acknowledgements[emitter][peer]` is a total fixed-cardinality projection; it is not a scalar global
ack and cannot clear another peer's debt. Its `pending` bit records whether the latest bounded
suffix still waits for that peer. `FoldCheckpoint` represents successful signing and installation
of one repair floor: it advances one fixed checkpoint slot to a committed record, clears the
absorbed pending flags and obsolete frame slots, and leaves no unbounded prefix. A lagging peer uses
`RepairFromCheckpoint`, then resumes immediate delivery. That action changes only the lagging
receiver's remote semantic projection; it never reconstructs, resets, or advances the emitter's
local journal authority.

The concrete runtime retains a bounded ordered suffix of exact assertion bytes rather than the
model's one representative pending frame. Native bounds and property tests prove list length,
payload bytes, peer membership, ordering, candidate-prefix identity, and corrupt-checkpoint
rejection. TLC proves the protocol shape: no semantic, pending, ack, or repair-floor position can
move beyond the applicable durable journal frontier.

### 1.4 Orders and DNS composition

Sprint `2.31` exhaustively checked independent Orders-promotion, credential, continuity-observation,
ranked-owner, and partition interleavings. The Sprint `2.32` configuration deliberately fixes
`activeOrders` at the already admitted identity while exploring the new actor/durability/fence
state space. It therefore does not model the concrete durable Orders-migration transaction or its
re-arm. Native tests own the version-3 prior-digest projection, migrated-projection crash before
publication, same-process final-fsync refusal, exact State-admission re-arm, and conflicting-evidence
rejection. `RestoreRuntimeGate` abstracts credential reacquisition plus ranked-owner recomputation
into one established-runtime action after restart. This factoring is an explicit model
decomposition, not a TLC state constraint, and the fixed `activeOrders` value must not be reported as
an exhaustive Orders-migration proof.

The DNS gate still composes with the new protocol: a write requires the ranked owner, a committed
claim under the admitted Orders identity, credentials, observable continuity, an idle journal, and
a live matching lock/incarnation/Lease fence. Stage admission, Lease expiry, and active-process
crash revoke a live DNS writer.

### 1.5 Legacy durable-boot liveness decomposition

The pre-cutover production topology cannot sustain the authored heartbeat frequency when every
heartbeat traverses its capacity-one remote Model-B stage/re-observe/commit transaction. The
separate legacy model therefore explores the bounded protocol used during qualification without
pretending that protocol is the target journal design:

1. `StartProcess` chooses a strictly newer finite boot identity but grants no liveness.
2. `PersistBootHeartbeat` represents the one ordinary signed persistence-first heartbeat. It makes
   the boot durable and exact for the local receiver, clears local predecessor liveness, and leaves
   an old frame in the finite delayed-network slot so rejection remains explored.
3. `EmitLiveness` is admitted only when the running boot, durable boot, and local observed boot are
   equal. It overwrites one source slot and one local receive slot with a positive monotonic
   sequence and current finite clock value.
4. `ObserveBootHeartbeat` advances one remote viewer to the emitter's durable boot and clears that
   viewer's old receive slot before a frame under the new fence can arrive.
5. `DeliverCurrentFrame` and `DeliverDelayedFrame` share `AcceptFrame`. Peer-to-peer delivery is
   never self-delivery; a candidate must name the viewer's exact observed boot, advance the current
   per-boot sequence, and carry a non-regressing timestamp.
6. `CrashProcess` removes the local source and local receive slot while retaining one delayed frame
   for adversarial delivery. `AdvanceClock` makes every unrefreshed slot expire under the finite
   heartbeat timeout.

The model abstracts the exact heartbeat coordinate/digest to a finite `boot` identity. Native
`SignedLivenessFrame` verification owns canonical CBOR, HMAC, exact Orders, emitter,
incarnation/epoch/sequence/digest, clock-skew, and byte limits. This decomposition checks the
protocol consequence: a fresh accepted frame never survives observation of another durable boot,
and local freshness exists only for a running process on its own durable fence. Claims, yields, and
DNS authorization remain persistence-first semantic transitions covered by the target/ownership
model and native composition tests; a liveness frame cannot encode them.

### 1.6 Lifecycle create ownership (Sprint `5.48`)

This model exists because the other two cannot reach the class that has produced four incidents
since May 2026. Thirty-four sprints applied a type-level device to cleanup, absence and residue;
each makes a *value* unconstructible and each claim is true, and none makes an *outcome in a cloud
account* unconstructible, which
[pure_fp_standards.md](./pure_fp_standards.md) now states as doctrine. A leak is not a value: it is
a property of an ordering across processes and crashes — which durable writes happened before the
effect that created a resource, and what survives a process that dies between them. That is a
protocol property, and a model checker is the instrument for it.

**The property is safety, not liveness.** "The resource is eventually absent in AWS" is a claim
about the world and does not belong inside a model property any more than inside a type, and
liveness over a reconciler with no fairness assumption yields a stuttering counterexample that
proves nothing. The checked property is:

> there is no reachable state in which a provider effect has landed and no durable record names the
> coordinates it created.

**The module carries its own frozen superseded ordering.** `WriteAheadEnabled` is a configured
constant. `FALSE` is the 2026-09-08 revision — a generation record names the cycle, nothing names
the resources — and `TRUE` is the ordering Sprint `7.41` schedules. Both configurations are
registered, the second is declared to expect a counterexample, and `prodbox dev tla-check` refuses
if it does not produce one. A model checked only in the configuration it passes under has been
observed to pass and never to refuse.

`durableManifests` is a slot per cycle rather than one slot. The first draft used one, and TLC found
in eleven steps that a second create's manifest erased the first's record; the correction is in the
model because it is also true of the runtime, where a manifest is committed at the submission key.

---

## 2. Variable-to-Runtime Correspondence

| TLA+ variable | Runtime correspondence |
|---|---|
| `running` | old and replacement gateway processes that may overlap during Pod restart |
| `journalLockHolder` | long-held POSIX `fcntl` write lock in `Prodbox.Gateway.Emitter.Journal` |
| `durableIncarnation` | monotonically increased, fsynced journal incarnation |
| `leaseHolder` | read-back-verified `coordination.k8s.io/v1 Lease` binding in `Emitter.Lease` / `Emitter.KubernetesLease` |
| `journal.phase`, `transitionOwner` | `Emitter.Kernel` in-flight phase plus its one admitted actor owner |
| `journal.activeAdmission`, `nextAdmission` | current `TransitionAdmission` and the monotonic, non-wrapping actor admission counter |
| `journal.stagedAdmission` | identity binding between the active transition and its exact immutable `StagedRecord` |
| `journal.deadlineOpen`, `lastPrePublish*` | finite deadline-open/expired abstraction and witness that successful pre-publish crossings used an open deadline |
| `journal.lastRejected*` | observable stale-ticket or wrong-exact-record completion rejection witness |
| `journal.committed*`, `journal.staged*` | encrypted identity-bound durable projection plus the in-flight plan/exact staged record in `Emitter.JournalAuthority` and `Emitter.Kernel` |
| `semantic` | bounded latest semantic checkpoint keyed by viewer and emitter |
| `pending` | one representative bounded immediate-publication slot per directed peer link |
| `acknowledgements` | per-peer `AckPoint` projection; no global scalar acknowledgement |
| `checkpoint` | installed signed `RepairFloor` that absorbs an unacknowledged prefix |
| `activeOrders` | admitted Orders identity deliberately held fixed during the Sprint `2.32` actor refinement; concrete durable migration/re-arm is native-tested |
| `ownerView`, `credentialReady`, `continuityObservable` | established DNS gate inputs and their restart restoration boundary |
| `dnsWriteNode` | current revocable DNS-write authority, not historical write telemetry |

The legacy-liveness model has its own closed correspondence:

| TLA+ variable | Runtime correspondence |
|---|---|
| `clock` | bounded abstraction of the POSIX-second timestamp and Orders heartbeat timeout |
| `runningBoot` | running process's would-be boot identity; the concrete `LegacyLivenessSession` is installed only after `durableBoot` commits |
| `durableBoot` | newest persistence-first signed heartbeat committed through legacy Model-B continuity |
| `observedBoot[viewer][emitter]` | viewer's `gatewayStateLatestHeartbeat emitter`, including the exact signed coordinate/digest used by verification |
| `sourceFrame` | local emitter's one `stateLivenessFrames` member slot selected for peer delivery |
| `delayedFrame` | one representative valid predecessor frame retained by an asynchronous network after source replacement or crash |
| `receivedFrame[viewer][emitter]` | receiver's one admitted liveness slot and corresponding `stateLastHeartbeatTimes` freshness projection |

The concrete actor additionally carries a bounded mailbox, the numeric absolute deadline, canonical
signed bytes, AEAD nonces, payload limits, and structured failures. Those mechanisms refine these
state transitions and are tested natively; TLC models deadline openness and bounded admission
identity, but not byte arrays, cryptography, clock arithmetic, or scheduler implementation.

---

## 3. TLC Domains and Production Bounds

The checked configuration is:

| Constant | TLC value | Meaning |
|---|---:|---|
| `Nodes` | `{n1, n2}` | representative emitter `n1` plus a real peer/acknowledger `n2` |
| `MaxIncarnation` | `2` | initial process plus one overlapping crash/restart incarnation |
| `MaxAdmission` | `3` | three monotonic, non-reused tickets, including a same-incarnation newer transition that can receive an older delayed completion |
| `MaxEpoch` | `1` | one non-wrapping epoch checkpoint |
| `MaxSequence` | `1` | ordinary assertion before and after epoch rotation |
| `MaxOrdersVersion` | `1` | established admitted Orders identity for this refinement |

The separately checked legacy-liveness configuration is:

| Constant | TLC value | Meaning |
|---|---:|---|
| `Nodes` | `{n1, n2}` | two independent peer identities, including both directed delivery choices |
| `MaxBoot` | `2` | predecessor plus one replacement durable fence, selected by either crash/restart or an in-process backend-proof refresh |
| `MaxFrameSequence` | `2` | first frame plus one monotonic replacement and delayed predecessor |
| `MaxTime` | `3` | finite clock steps spanning fresh and expired observations |
| `HeartbeatTimeout` | `2` | strict freshness window inside the finite clock domain |

The actor protocol is emitter-local. `Rank1` is the representative emitter; `Rank2` retains an
independent lock/incarnation/Lease identity and acts as the directed receiver/acknowledger. Enabling
a second interchangeable copy of the same actor squares the independent state product without
adding a cross-emitter transition. Cross-emitter ranked-owner and partition behaviour remains the
Sprint `2.31` proof axis; this model freshly checks its composition with the representative actor's
journal and fence gate.

Neither configuration uses a TLC `CONSTRAINT`, `ACTION_CONSTRAINT`, `StateConstraint`, or symmetry
collapse. `CHECK_DEADLOCK FALSE` is intentional because sequence/incarnation/time exhaustion
produces valid terminal states in these safety-only bounded models; it does not remove a state or
transition.

Finite domains make exhaustive exploration possible; they are not production limits. Production
cardinality and byte bounds are separately enforced by validated Orders limits, mailbox capacity,
maximum exact payload bytes, maximum retained assertion count, per-peer acknowledgement maps, and
the resource-envelope/soak proof axes.

---

## 4. Checked Invariants

| Invariant | Meaning |
|---|---|
| `TypeOK` | Every variable stays inside its finite typed domain. |
| `LeaseBindsDurableIncarnation` | A Lease holder is the running OS-lock holder and equals the fsynced incarnation; a lock holder is never older than durable state. |
| `SingleWriterActorIsFenced` | Each emitter has at most one transition owner, and that owner has the complete lock/incarnation/Lease fence. |
| `JournalProtocolShape` | Idle, unsigned staging, un-fsynced exact stage, durable stage, published, and commit-written states contain only their permitted witnesses and sentinels. |
| `AdmissionIdentityFencesCompletions` | An active ticket is monotonic and non-reused; unsigned staging has no record ticket, while every exact staged phase binds the record ticket to the active transition. |
| `DelayedCompletionIsRejectedByIdentity` | Every observable rejection witness is either an older transition ticket or an older exact-record ticket presented against the current transition. |
| `NoDeadAdmissionAdvancedPrePublish` | Every successful stage, stage-fsync, or publish witness crossed while its governing admission deadline was open. |
| `StagedTransitionIsNonWrapping` | A stage carries a non-regressing incarnation and is either the immediate sequence successor or the only permitted next-epoch checkpoint. |
| `SemanticIsOrdersScoped` | Every non-empty semantic record is scoped to its viewer's admitted Orders identity. |
| `IncarnationFenceIsMonotonic` | Committed, staged, semantic, pending, ack, and checkpoint incarnations never exceed their applicable durable incarnation and checkpoints never exceed committed incarnation. |
| `NoSemanticAheadOfDurableJournal` | No viewer observes a position beyond the committed record or one exact fsynced staged frontier. |
| `PendingSlotsAreBoundedAndDurable` | Every directed link has exactly one empty or durable bounded frame slot; empty slots carry only sentinels. |
| `AcknowledgementsAreBoundedAndDurable` | Every peer has one acknowledgement slot and no acknowledgement advances beyond the durable frontier. |
| `CheckpointIsCommittedAndBounded` | Each emitter has one repair floor and it never advances beyond the committed journal record. |
| `DnsLeaseRequiresCompleteGate` | A live DNS writer continues to satisfy the complete ownership, claim, Orders, credential, journal-idle, and writer-fence gate. |
| `NoSimultaneousDNSWriters` | Under a stable ranked view, no more than one node satisfies the complete DNS gate. |

The legacy-liveness module checks six separately scoped invariants:

| Invariant | Meaning |
|---|---|
| `TypeOK` | Every clock, boot, and frame slot stays inside its finite typed domain; an absent slot carries only sentinels. |
| `LocalBootObservationIsExact` | Each local receiver's heartbeat projection and compacted-cursor witness are exactly its durable Model-B fence. |
| `SourceFrameHasLiveDurableFence` | A source frame exists only for a running process whose boot equals its durable fence. |
| `AcceptedFrameHasAuthenticatedFenceEvidence` | Every retained receive slot names either the receiver's exact heartbeat projection or its compacted-cursor witness for the durable fence. |
| `FreshFrameHasAuthenticatedFenceEvidence` | No fresh frame under the timeout can count without one of those exact authenticated fence observations. |
| `FreshLocalFrameRequiresLiveDurableBoot` | Local freshness requires a running process on its own durable boot, so recovered predecessor evidence alone cannot self-elect. |

The lifecycle create-ownership module checks six separately scoped invariants:

| Invariant | Meaning |
|---|---|
| `TypeOK` | Every phase, cycle, manifest and resource set stays inside its finite typed domain. |
| `EveryProviderResourceIsDurablyNamed` | Every coordinate that exists in the provider is named by the declared set of some durable manifest, so a later run can reach it. It asserts naming and never absence. |
| `GenerationNamesACycleAndNeverAResource` | The generation record's domain is cycles, which is the precise sense in which the 2026-09-08 cycle was addressable while its cluster was not. |
| `DispatchFollowsReadBackWriteAhead` | Under the write-ahead ordering, no effect is dispatched until the manifest declaring its coordinates is committed *and* independently read back. |
| `AppendedIdentitiesAreDeclared` | An append narrows to what the write-ahead declared; it never widens the claim. |
| `ScratchIsNeverTheOnlyRecord` | A coordinate held only in the process is never the sole record of it — the property the retired checkpoint interpreter violated. |

These are safety properties. Progress depends on scheduling, transport, Kubernetes API, storage,
and credential availability. Native deterministic schedules and daemon/integration tests own those
liveness and timeout obligations.

---

## 5. Deliberate Abstractions

The model does not prove:

- AEAD, signature, hash, CBOR, or Dhall encoder correctness
- POSIX lock, rename, file/directory `fsync`, or Kubernetes Lease client implementation correctness
- resource-version conflict retry, read-back timing, or wall-clock/monotonic-clock conversion
- exact assertion, serialized checkpoint, frame, queue-entry, mailbox, parser, or heap byte
  accounting
- TCP partial reads, timeouts, OS scheduling, Vault/MinIO/Route 53 availability, or GHC residency
- liveness during an unbounded asynchronous partition
- operational cutover or deployment qualification

The legacy model abstracts both HMAC checks as possession of a frame emitted under one finite
durable fence and does not model raw Orders bytes, signature/digest collisions, POSIX clock rollback,
or network bandwidth. `observedBoot` represents a full latest-heartbeat projection;
`observedCursorBoot` represents the at-or-after same-incarnation/epoch compacted cursor admitted by
the native verifier. `RefreshBackendProof` treats the newly committed semantic heartbeat and local
session replacement as one fence transition; the native transaction and race are covered by tests
and the rule that an old-session frame fails local verification after publication. Native
constructors and peer tests own those byte-level checks. The model's `delayedFrame` is one
adversarial predecessor slot, sufficient to exercise rejection after crash, in-process proof
rotation, and either receiver observation shape; it is not a claim that a real network retains only
one packet. The 60-second refresh cadence and 300-second readiness freshness window are runtime
constants rather than a temporal-progress property of this safety-only model.

The deadline bit deliberately abstracts the native `Prodbox.ControlPlane.Capacity` arithmetic. For
a plan with `workers` servers and `serviceTime` microseconds, native admission computes queue wait
as `(ahead div workers) * serviceTime`, then charges `queueWait + serviceTime` for the request. It
rejects saturation when `depth >= rejectionThreshold` and admits a deadline only when the remaining
budget is strictly greater than that total cost; equality is a deadline miss. Replacement admission
keeps the exact FIFO position and queue depth, recomputes the same cost at that position, and leaves
the original request untouched if the replacement misses its deadline. Unit/property tests own
that queue, replacement, cancellation, threshold, and absolute-clock math. TLC owns the protocol
consequence: no successful pre-publish phase crosses while the bounded deadline state is closed.

### 5.1 Bounded delay and the runtime clock-skew bound

The gateway models assume a bounded-delay network and clocks that agree within a bound: `AdvanceClock`
steps every node's clock together, `HeartbeatTimeout` is a strict freshness window inside that finite
domain, and `AcceptFrame` requires a non-regressing timestamp. TLC does not fix the bound's size and
does not check that the runtime bound is small relative to the heartbeat timeout; that is a property
of the operator's configuration. The runtime does not get the assumption for free. It enforces it in
three places, and each names its bound and what an operator does when it is crossed:

| Model assumption | Runtime enforcement | Bound | Operator response |
|---|---|---|---|
| Nodes share a time base | `prodbox host info` fails fast when `timedatectl` reports the clock unsynchronized (`NtpUnsynced`). A host without `timedatectl` reports an unknown disposition and is not blocked. | NTP synchronized | Restore NTP synchronization on the host before starting or restarting the daemon. |
| Clocks agree within a bound | The daemon refuses an inbound event whose timestamp lies beyond the bound, and the push response lists it under `rejected` with the offending skew. | `max_clock_skew_seconds`: default 10 seconds, range `[0.1, 600]` | Find the node the rejection names and correct its time source; a widened bound is a configuration change that widens the window in which a stale claim can be accepted. |
| Drift is visible before it matters | The daemon records the maximum inter-node skew it has observed on `/v1/state` as `max_clock_skew_seconds_observed`, beside `max_clock_skew_seconds_bound`. | observed maximum against the bound | Treat an observed maximum approaching the bound as the signal to correct the clock, before events begin to be rejected. |

POSIX clock rollback and the conversion between wall-clock and monotonic time remain outside the model.

The lifecycle create-ownership model additionally does not prove:

- that any particular repository function implements the ordering it models. The model proves the
  **protocol** and never the boundary implementation; whether
  `commitOwnershipManifestWriteAheadAttempt` is called before the execute step is a source fact
  Sprint `7.41` owns and the guard-consumption gate observes, not a model fact.
- anything about the provider. `providerResources` is an abstraction of a database this repository
  does not own; the model gives it no failure modes, no partial visibility, and no eventual
  consistency, and a real account has all three.
- that the declared coordinate set is the right one. `CommitWriteAheadManifest` may declare any
  non-empty subset, and whether a real create's authorized coordinate set is known before the
  effect is a provisioning-program fact outside the model.
- retry, idempotency, or the identity of a re-dispatched effect. A cancelled reply followed by a new
  admission takes a fresh cycle here; a real create may be re-dispatched under the same key, and the
  replay identity that makes that safe is Sprint `7.36`'s dispatch digest, exercised by unit tables
  rather than by TLC.
- any bound on time. There is no clock: `CancelReply` is enabled from dispatch onward without a
  deadline being modelled, which is deliberately more permissive than the runtime.

Native tests cover exact payload retention, corruption rejection, lock exclusion, monotonic
incarnation, Lease conflicts/read-back/expiry, stale admission and exact-record completion
rejection, pre-publish deadline expiry/recovery, mailbox saturation, per-peer acknowledgement
behavior, checkpoint candidate validation, every-signed-phase durable-stage rewind and exact
republication, journal-first initialization/marker read-back crash asymmetry, local journal recovery
versus remote-only peer repair, and the migrated-projection/pre-publication and final-fsync Orders
re-arm cases excluded by the fixed-`activeOrders` decomposition. Deployment
qualification and live fault matrices remain separate evidence axes under Development Plan
Standard P.

---

## 6. Verification Result

Run:

```bash
prodbox dev tla-check
```

`src/Prodbox/Tla.hs` runs each registered model through TLC 2.18 in a separate pinned
`maxdiefenbach/tlaplus` container with eight workers and records the combined result in
`documents/engineering/tla/tlc_last_run.txt`.

The Sprint `2.32` configuration completed exhaustive exploration on 2026-07-20 with no invariant
violation:

- 7,139,920 states generated
- 781,710 distinct states checked
- depth 44
- zero states left on the queue
- all 16 configured invariants passed

A separate diagnostic TLC coverage pass reached every new actor/journal/fence/ack/checkpoint action,
including admission begin/stage completion, deadline expiry/recovery, delayed-completion rejection,
heartbeat and claim assertions, epoch checkpoint, both fsync barriers, Lease expiry, process crash,
durable-stage resume, peer acknowledgement, checkpoint fold, checkpoint repair, and runtime gate
restoration. The canonical evidence remains the unconstrained `prodbox dev tla-check` result above.

The post-checkpoint-witness/backend-proof canonical run on 2026-09-05 UTC kept that target result
exact and exhaustively checked the legacy-liveness configuration with no invariant violation:

- 14,683,109 states generated
- 2,233,608 distinct states checked
- depth 26
- zero states left on the queue
- all six configured legacy-liveness invariants passed

The first draft failed `FreshLocalFrameRequiresLiveDurableBoot`: it permitted a crashed node to
accept its own delayed frame. That trace changed both model and runtime. Peer delivery now excludes
self-delivery, and the daemon additionally requires its process-local durable-boot session and
local frame before legacy ownership. The green run is therefore post-counterexample evidence, not
the uncorrected first model.

The enlarged run additionally covers a periodic persistence-first fence refresh and a receiver
whose compacted cursor proves the embedded signed boot while its latest-heartbeat projection is
absent. Delayed predecessor frames remain inadmissible after both restart and in-process rotation.

The lifecycle create-ownership configurations were first checked on 2026-09-14 UTC, over
`Coordinates = {vpc, cluster}` and `Cycles = {c1, c2}`.

The write-ahead ordering completed exhaustive exploration with no invariant violation:

- 2,993 states generated
- 1,750 distinct states checked
- depth 18
- zero states left on the queue
- all six configured invariants passed

The frozen superseded ordering produced the counterexample it is registered to produce, in five
states: `Admit`, `CommitGeneration`, `DispatchEffect`, `LandEffect` — and
`EveryProviderResourceIsDurablyNamed` is violated at the fourth transition, before any crash is
needed. That is the 2026-09-08 shape stated as a trace: the generation record is committed, the
effect lands, and nothing durable names what it created. It is registered evidence that the model
can fail rather than a defect in the tree.

This result covers only the finite model and assumptions documented here. It does not claim
deployment qualification or replace native and live-infrastructure validation.

---

## Cross-References

- [Distributed Gateway Architecture](./distributed_gateway_architecture.md)
- [TLA+ model](./tla/gateway_orders_rule.tla)
- [TLA+ configuration](./tla/gateway_orders_rule.cfg)
- [Legacy liveness model](./tla/gateway_legacy_liveness.tla)
- [Legacy liveness configuration](./tla/gateway_legacy_liveness.cfg)
- [Lifecycle create-ownership model](./tla/lifecycle_create_ownership.tla)
- [Lifecycle create-ownership configuration](./tla/lifecycle_create_ownership.cfg)
- [Frozen superseded ordering configuration](./tla/lifecycle_create_ownership_superseded.cfg)
- [Chaos Hardening Doctrine](./chaos_hardening_doctrine.md)
- [Runtime memory doctrine](./resource_scaling_doctrine.md)
- [Development plan](../../DEVELOPMENT_PLAN/README.md)
