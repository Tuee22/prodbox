# TLA+ Modelling Assumptions

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: DEVELOPMENT_PLAN/README.md, DEVELOPMENT_PLAN/phase-2-gateway-dns.md, documents/engineering/README.md, documents/engineering/distributed_gateway_architecture.md, documents/engineering/chaos_hardening_doctrine.md
**Generated sections**: none

> **Purpose**: Define the gateway emitter model-to-runtime correspondence, the finite actor,
> journal, fencing, acknowledgement, and checkpoint domains explored by TLC, and the boundary
> between formal safety evidence and native/runtime proof.

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

The specification is
[`documents/engineering/tla/gateway_orders_rule.tla`](./tla/gateway_orders_rule.tla). The completed
Sprint `2.32` refinement adds one representative per-emitter single-writer actor, one real peer
boundary, an explicit two-barrier journal protocol, and the incarnation/Lease fences that admit a
writer to the bounded semantic gateway model.

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

The actor protocol is emitter-local. `Rank1` is the representative emitter; `Rank2` retains an
independent lock/incarnation/Lease identity and acts as the directed receiver/acknowledger. Enabling
a second interchangeable copy of the same actor squares the independent state product without
adding a cross-emitter transition. Cross-emitter ranked-owner and partition behaviour remains the
Sprint `2.31` proof axis; this model freshly checks its composition with the representative actor's
journal and fence gate.

The configuration uses no TLC `CONSTRAINT`, `ACTION_CONSTRAINT`, `StateConstraint`, or symmetry
collapse. `CHECK_DEADLOCK FALSE` is intentional because sequence/incarnation exhaustion produces
valid terminal states in this safety-only bounded model; it does not remove a state or transition.

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

The deadline bit deliberately abstracts the native `Prodbox.ControlPlane.Capacity` arithmetic. For
a plan with `workers` servers and `serviceTime` microseconds, native admission computes queue wait
as `(ahead div workers) * serviceTime`, then charges `queueWait + serviceTime` for the request. It
rejects saturation when `depth >= rejectionThreshold` and admits a deadline only when the remaining
budget is strictly greater than that total cost; equality is a deadline miss. Replacement admission
keeps the exact FIFO position and queue depth, recomputes the same cost at that position, and leaves
the original request untouched if the replacement misses its deadline. Unit/property tests own
that queue, replacement, cancellation, threshold, and absolute-clock math. TLC owns the protocol
consequence: no successful pre-publish phase crosses while the bounded deadline state is closed.

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

`src/Prodbox/Tla.hs` runs TLC 2.18 in the pinned `maxdiefenbach/tlaplus` container with eight
workers and records the result in `documents/engineering/tla/tlc_last_run.txt`.

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

This result covers only the finite model and assumptions documented here. It does not claim
deployment qualification or replace native and live-infrastructure validation.

---

## Cross-References

- [Distributed Gateway Architecture](./distributed_gateway_architecture.md)
- [TLA+ model](./tla/gateway_orders_rule.tla)
- [TLA+ configuration](./tla/gateway_orders_rule.cfg)
- [Chaos Hardening Doctrine](./chaos_hardening_doctrine.md)
- [Runtime memory doctrine](./resource_scaling_doctrine.md)
- [Development plan](../../DEVELOPMENT_PLAN/README.md)
