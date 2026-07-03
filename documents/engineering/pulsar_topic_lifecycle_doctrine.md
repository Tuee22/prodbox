# Pulsar Topic Lifecycle Doctrine

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md),
[../../DEVELOPMENT_PLAN/phase-4-lifecycle-canonical-paths.md](../../DEVELOPMENT_PLAN/phase-4-lifecycle-canonical-paths.md),
[tiered_storage_capacity_doctrine.md](tiered_storage_capacity_doctrine.md)
**Generated sections**: none

> **Purpose**: Establish that a Pulsar topic is a first-class prodbox managed resource — typed
> three-valued broker discover, typed destroy, a lifecycle class, and a name only the topic algebra
> can produce — reconciled to present/absent idempotently through the same registry every other
> resource uses.

The code-owned surface landed in Sprint `4.35`: `Prodbox.Pulsar.TopicResidue` owns
`ManagedTopic`, `TopicResidueStatus`, `topicDiscover`, `ensureTopic`, `deleteTopic`, and the total
projection onto `ResidueStatus`; `Prodbox.Lifecycle.ResourceClass` registers the topic-family rows;
`Prodbox.Lifecycle.ResourceRegistry` adapts concrete managed topics into the shared destroy surface;
and `Prodbox.Pulsar.Admin` provides the broker-backed admin implementation. The live home-local
`pulsar-broker` validation proves admin-backed ensure/discover/delete against a real broker and
verifies absence after deletion. The canonical Dhall schema for the topic family remains a later
code artifact (`dhall/PulsarTopicSchema.dhall`, mirroring jitML's `dhall/project/Schema.dhall`);
this document describes facets and shows teaching-example fragments — it is **not** the schema SSoT.

## 1. A Topic Is a Managed Resource

A Pulsar topic is not a side effect a daemon performs — it is one entry in the **managed-resource
registry** defined by
[lifecycle_reconciliation_doctrine.md § 3.1](lifecycle_reconciliation_doctrine.md#31-the-managed-resource-registry-the-reconciler-substrate).
It carries the same three obligations as every other registered resource — a typed `discover`, a
typed `destroy`, and a `LifecycleClass` — and its full lifecycle (**create → retain/offload →
delete**) is reconciled by the same `reconcilePresent` / `reconcileAbsent` reconcilers, idempotent by
construction. This doctrine does **not** restate the registry pattern, the Totality / Soundness /
Idempotent invariants, or the `Unreachable → refuse` rule; it consumes them and links back.

The registry stays "data in, data out": adding topics adds registry rows, never a bespoke topic state
machine. Topic authority lives in the broker, which this process cannot refresh transactionally, so
the answer is a pure `discover` queried at the moment of use — exactly the reasoning in
[§3 "Why not a global state machine"](lifecycle_reconciliation_doctrine.md#why-not-a-global-state-machine).

## 2. Topic Names Come Only From the Topic Algebra

A hand-authored topic string is **unrepresentable**. Topic names are produced solely by the typed
topic algebra `topicFor` owned by
[pulsar_messaging_doctrine.md](pulsar_messaging_doctrine.md) — prodbox mirrors, in kind, jitML's
`topicFor :: Tenant -> Namespace -> Workflow -> Phase -> Lane -> TopicName`. `TopicName` is an opaque
newtype with no exported constructor, so the only way to obtain one is through the algebra:

```haskell
-- Example: a managed topic can only name a topic the algebra produced
newtype TopicName = TopicName Text        -- opaque; constructor not exported

-- the ONLY builder (SSoT: pulsar_messaging_doctrine.md)
topicFor :: Tenant -> Namespace -> Workflow -> Phase -> Lane -> TopicName

data ManagedTopic = ManagedTopic
  { managedTopicName      :: TopicName        -- from topicFor, never a literal
  , managedTopicRetention :: RetentionPolicy  -- owned by tiered_storage_capacity_doctrine.md (§5)
  , managedTopicClass     :: LifecycleClass    -- Prodbox.Lifecycle.ResourceClass (§4)
  }
```

Because `TopicName` cannot be spelled, a registry entry, a producer binding, or a destroy target that
names a topic the algebra never generated fails to compile — the same "undeclared is unnameable"
guarantee jitML gets from its closed `StoreId` union and exhaustive `merge` (see
`durable_state_dsl.md` in the sibling jitML repo).

## 3. Broker-Observed Status Models "Unobservable" Explicitly

A topic's `discover` asks the broker and returns a three-valued status whose middle-of-the-night
failure mode — "I could not reach the broker" — is a **first-class arm**, never silently collapsed
into "absent." This mirrors [`ResidueStatus`](../../src/Prodbox/Lifecycle/ResidueStatus.hs)
(`ResidueAbsent | ResiduePresent | ResidueUnreachable`) and the gateway
[`Disposition`](../../src/Prodbox/Gateway/Types.hs) projection
(`DispositionOwner | DispositionYielded | DispositionUnknown`) — both cases where the honest
"unknown/unobservable" outcome is a constructor, not a boolean:

```haskell
-- Example: broker-observed topic status — "cannot observe" is a constructor
data TopicResidueStatus
  = TopicAbsent                                -- broker reachable; topic not present
  | TopicPresent !TopicResidueDetails          -- broker reachable; topic exists (+ backlog/offload evidence)
  | TopicUnobservable !TopicUnobservableReason  -- broker/admin API unreachable — NOT "absent"

topicDiscover :: PulsarTopicBroker -> ManagedTopic -> IO TopicResidueStatus
```

To plug into the registry unchanged, a **total projection** maps this domain status onto the
registry's `ResidueStatus`, so a topic reuses the existing soundness combinator
`residueBlocksTeardownGate` (`present OR unreachable → block`) rather than re-deriving gate logic:

```haskell
-- Example: total projection onto the registry's three-valued status
topicResidueStatus :: TopicResidueStatus -> ResidueStatus
topicResidueStatus TopicAbsent            = ResidueAbsent
topicResidueStatus (TopicPresent d)       = ResiduePresent (toResidueDetails d)
topicResidueStatus (TopicUnobservable r)  = ResidueUnreachable (toUnreachableReason r)
```

The
[§3.1 invariant 2 (Soundness)](lifecycle_reconciliation_doctrine.md#31-the-managed-resource-registry-the-reconciler-substrate)
rule then applies verbatim: a teardown gate over a `TopicUnobservable` topic **refuses**. "I cannot
read the broker" is not "the topic is gone"; treating it as gone would delete a topic's declared
offload budget out from under a topic whose segments still occupy MinIO. A broker that is reachable
and reports the topic missing is positive evidence of `TopicAbsent`, which passes — the same
absent-is-observed distinction §3.1 draws for a never-created checkpoint.

## 4. The Managed-Topic Registry Entry

Each topic decorates its pure facts (name + class, from
[`Prodbox.Lifecycle.ResourceClass`](../../src/Prodbox/Lifecycle/ResourceClass.hs)) with the IO
`discover` / `destroy` actions, exactly as the AWS/cluster resources do:

```haskell
-- Example: a topic as one ManagedResource row (registry shape from §3.1)
managedTopicResource :: PulsarTopicBroker -> ManagedTopic -> ManagedResource
managedTopicResource broker t = ManagedResource
  { resourceName     = renderTopicName (managedTopicName t)
  , resourceClass    = managedTopicClass t
  , resourceDiscover = topicResidueStatus <$> topicDiscover broker t
  , resourceDestroy  = deleteTopic broker t     -- idempotent: Absent → skip
  }
```

Topics take an **existing** `LifecycleClass`, they do not introduce a new one:

- **`PerRun`** — an ephemeral per-workflow topic whose backlog dies with the run. `reconcileAbsent`
  over the `PerRun` class removes it, and an unreachable broker during a `--cascade` teardown
  degrades gracefully under the documented per-run exception (the run is ending regardless).
- **`LongLived`** — a durable topic whose offloaded segments live in MinIO and outlive any single
  run. Like `aws-ses` and the retained public-edge certificate, it is destroyed only by an explicit
  long-lived teardown (`prodbox nuke`), never by `cluster delete`, and its `TopicUnobservable`
  status is always a refusal.

**Totality** (§3.1 invariant 1) extends to topics without amendment: no prodbox code path may create
a topic that is not a registered `ManagedResource` with a `discover` and a `destroy`. The
`check-code` registry ↔
[`substrates.md` Resource Lifecycle Classes](../../DEVELOPMENT_PLAN/substrates.md#resource-lifecycle-classes)
parity scan that already makes "a creatable-but-undiscoverable resource" unrepresentable covers
topic rows the moment they are added there.

## 5. Retention and Offload Draw Down the Finite Budget

A topic's `RetentionPolicy` — how much backlog it keeps and when segments offload to object storage —
is **owned by** [tiered_storage_capacity_doctrine.md](tiered_storage_capacity_doctrine.md), which
holds the finite MinIO/storage budget. This doctrine only **consumes** it: a `LongLived` topic's
offloaded segments are a line item in that budget, so a topic's retention draws it down alongside
every other stored object.

The consequence is a static invariant, not a runtime check: a `ManagedTopic` whose retention/offload
would exceed the budget is **unrepresentable**. The topic family's Dhall `assert : contractOK self
=== True` includes the capacity doctrine's `storageFitsWithin` lemma, so an over-budget topology is a
typecheck failure before any broker call — mirroring jitML's durable-state DSL, where the same
`storageFitsWithin` / `retentionWellFormed` lemmas reject an over-quota or malformed-retention store
(`durable_state_dsl.md` in the sibling jitML repo). This doctrine does not restate the budget
arithmetic; see the capacity doctrine's `storageFitsWithin`.

## 6. Illegal Topic States Are Unrepresentable

| Illegal state | Rejected by |
|---|---|
| A topic named by a literal string | Unnameable — `TopicName` has no exported constructor; only `topicFor` ([§2](#2-topic-names-come-only-from-the-topic-algebra)) builds one |
| A topic prodbox can create with no `discover`/`destroy` | `check-code` registry ↔ `substrates.md` parity (Totality, §3.1 invariant 1) |
| A teardown gate silently passing on an unreachable broker | `residueBlocksTeardownGate` — `TopicUnobservable → refuse` (Soundness, §3.1 invariant 2) |
| Retention/offload exceeding the storage budget | `storageFitsWithin` — the Dhall `assert : contractOK self === True` reduces to `False` ([§5](#5-retention-and-offload-draw-down-the-finite-budget)) |
| Malformed retention (e.g. `LastN 0`) | `retentionWellFormed`, owned by [tiered_storage_capacity_doctrine.md](tiered_storage_capacity_doctrine.md) |

## 7. Scheduling

This doctrine landed in
[Phase 4 Sprint 4.35](../../DEVELOPMENT_PLAN/phase-4-lifecycle-canonical-paths.md) — *Pulsar topics as
managed resources*: the `ManagedTopic` topic-family rows, the `TopicResidueStatus` discover, the
total projection onto `ResidueStatus`, typed `ensureTopic` / `deleteTopic`, and the
`pulsarTopicManagedResource` adapter. The same closure added `Prodbox.Pulsar.Admin` as the live
admin REST broker adapter and proved broker-backed ensure/discover/delete in
`./.build/prodbox test integration pulsar-broker`. Sprint `4.35` consumed the
[Phase 3 Sprint 3.21](../../DEVELOPMENT_PLAN/README.md) Pulsar client boundary after its
repo-owned broker transport/framing closed.

## Intent Ownership

This doctrine owns "a Pulsar topic is a managed resource" intention.

- Owned statement: a Pulsar topic is a first-class registered managed resource — a typed three-valued
  broker `discover` with an explicit unobservable arm, a typed idempotent `destroy`, an existing
  `LifecycleClass`, and a name only the topic algebra can produce — reconciled to present/absent
  through the [§3.1](lifecycle_reconciliation_doctrine.md#31-the-managed-resource-registry-the-reconciler-substrate)
  registry, with retention drawn from the finite storage budget.
- Linked dependents: `src/Prodbox/Pulsar/Topic.hs` (topic-algebra mirror landed in Sprint `3.21`),
  `src/Prodbox/Pulsar/TopicResidue.hs` (`ManagedTopic`, `TopicResidueStatus`, `topicDiscover`,
  `ensureTopic`, `deleteTopic`, and the projection), `src/Prodbox/Pulsar/Admin.hs` (broker-backed
  admin adapter), `src/Prodbox/Pulsar/Client.hs` (Sprint `3.21` broker boundary),
  `src/Prodbox/Lifecycle/ResourceClass.hs` (topic-family class facts), and
  `src/Prodbox/Lifecycle/ResourceRegistry.hs` (topic managed-resource adapter).

## Cross-References

- [lifecycle_reconciliation_doctrine.md § 3.1](lifecycle_reconciliation_doctrine.md#31-the-managed-resource-registry-the-reconciler-substrate) — the managed-resource registry this doctrine plugs into
- [pulsar_messaging_doctrine.md](pulsar_messaging_doctrine.md) — the topic algebra (`topicFor`) that owns topic names
- [tiered_storage_capacity_doctrine.md](tiered_storage_capacity_doctrine.md) — the finite storage budget and `RetentionPolicy` this doctrine consumes
- [storage_lifecycle_doctrine.md](storage_lifecycle_doctrine.md) — the retained MinIO storage that offloaded segments occupy
- [pure_fp_standards.md](pure_fp_standards.md) — ADTs over strings, exhaustive matching, Plan/Apply
- [README.md](README.md) — engineering doctrine index
- [../../DEVELOPMENT_PLAN/phase-4-lifecycle-canonical-paths.md](../../DEVELOPMENT_PLAN/phase-4-lifecycle-canonical-paths.md) — Sprint 4.35 scheduling
