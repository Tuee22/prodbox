# Pulsar Topic Lifecycle Doctrine

**Status**: Authoritative source
**Supersedes**: N/A
**Generated sections**: none

> **Purpose**: Establish that a Pulsar topic is a first-class prodbox managed resource — exact
> broker observation, closed ensure/destroy program tags, a lifecycle class, and a name only the
> topic algebra can produce — reconciled idempotently through the same registry every other resource
> uses.

**Current source correspondence.** `Prodbox.Pulsar.TopicResidue` owns
`ManagedTopic`, `TopicResidueStatus`, `topicDiscover`, `ensureTopic`, `deleteTopic`, and the total
projection onto `ResidueStatus`; `Prodbox.Lifecycle.ResourceClass` registers the topic-family rows;
`Prodbox.Lifecycle.ResourceRegistry` adapts concrete managed topics into the shared destroy surface;
and `Prodbox.Pulsar.Admin` provides the broker-backed admin implementation. This is the pre-cutover,
three-valued callback adapter. No canonical topic-family Dhall schema exists in the current tree;
this doctrine neither reserves a schema path nor schedules one. Schema-shaped fragments below are
teaching examples of the invariant, not claims that an executable schema artifact exists.

That current `ResidueStatus`/callback adapter is pre-cutover implementation provenance. The target
registry described below stores exact coordinates and closed program tags rather than `IO` actions;
migration and qualification status remain in the
[Development Plan](../../DEVELOPMENT_PLAN/README.md#resume-here), and retirement of
callback-era lifecycle surfaces is tracked in the
[legacy deletion ledger](../../DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md#pending-removal).

## 1. A Topic Is a Managed Resource

A Pulsar topic is not a side effect a daemon performs — it is one entry in the **managed-resource
registry** defined by
[lifecycle_reconciliation_doctrine.md § 3.1](lifecycle_reconciliation_doctrine.md#31-the-managed-resource-registry-and-exact-observation-boundary).
It carries the same obligations as every other registered resource: an exact key/coordinate, a
`LifecycleClass`, closed observe/ensure/destroy program tags, and mandatory read-back evidence. Its
full lifecycle (**create → retain/offload → delete**) is interpreted through the shared
desired-present and desired-absence programs. This doctrine does not restate the registry pattern or
its Coverage, Soundness, Scope, Cardinality, and Completion invariants; it consumes them and links
back.

The registry stays "data in, data out": adding topics adds registry rows, never a bespoke topic state
machine. Topic authority lives in the broker, which this process cannot refresh transactionally, so
the interpreter observes it at the moment of use and returns a flat typed result — exactly the
reasoning in
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

## 3. Broker Observation Models Partial and Unobservable Explicitly

The broker interpreter returns a flat exhaustive result whose middle-of-the-night failure mode — "I
could not reach the broker" — is a first-class arm, never silently collapsed into absence. The
result is bound to the registered topic key, coordinate digest, broker authority, and observation
revision before the lifecycle decision may consume it:

```haskell
-- Example: hypothetical exact topic observation
data TopicObservationResult topic
  = TopicObservedAbsent (AbsenceEvidence topic 'Topic)
  | TopicObservedPresent (ExactTopicInventory topic)
  | TopicObservationPartial
      (PartialTopicInventory topic)
      (NonEmpty TopicObservationFailure)
  | TopicObservationUnobservable (NonEmpty TopicObservationFailure)

data ExactTopicObservation topic = ExactTopicObservation
  { topicObservationRef :: RegisteredResourceRef topic 'Topic
  , topicCoordinateDigest :: ManagedResourceCoordinateDigest
  , topicObservationAuthority :: BrokerAuthority
  , topicObservationRevision :: ObservationRevision
  , topicObservationResult :: TopicObservationResult topic
  }
```

The
[§3.1 Soundness invariant](lifecycle_reconciliation_doctrine.md#31-the-managed-resource-registry-and-exact-observation-boundary)
rule then applies verbatim: a desired-absence decision over a partial or unobservable topic
**refuses**. "I cannot
read the broker" is not "the topic is gone"; treating it as gone would delete a topic's declared
offload budget out from under a topic whose segments still occupy MinIO. A broker that is reachable
and reports the exact topic missing produces `TopicObservedAbsent`, which can close only that keyed
obligation.

## 4. The Managed-Topic Registry Entry

Each topic decorates its pure facts (name + class, from
[`Prodbox.Lifecycle.ResourceClass`](../../src/Prodbox/Lifecycle/ResourceClass.hs)) with closed
program tags, exactly as the AWS/cluster resources do:

```haskell
-- Example: hypothetical topic-specific registry binding
data TopicLifecycleBinding topic (life :: LifecycleClass) = TopicLifecycleBinding
  { topicResourceRef :: RegisteredResourceRef topic 'Topic
  , topicCoordinate :: TopicCoordinate
  , topicObserverProgram :: ObserverProgramTag topic 'Topic
  , topicEnsureProgram :: EnsureProgramTag topic
  , topicDestroyProgram :: DestroyProgramTag topic 'Topic
  }
```

`TopicLifecycleBinding` and the typed references/program tags have private constructors. The
registry contains no broker handle, endpoint, client, callback, or `IO`. The interpreter is the only
boundary that maps these tags to the broker admin API, and it must re-observe the same exact
topic reference after ensure or destroy.

Topics take an **existing** `LifecycleClass`, they do not introduce a new one:

- **`PerRun`** — an ephemeral per-workflow topic whose backlog dies with the run. Ordinary cleanup
  may project it into the desired-absence graph. An unreachable broker refuses absence and preserves
  the nonterminal obligation; the fact that the run is ending does not mint broker evidence.
- **`LongLived`** — a durable topic whose offloaded segments live in MinIO and outlive any single
  run. Like `aws-ses` and the retained public-edge certificate, it is destroyed only by an explicit
  long-lived teardown (`prodbox nuke`), never by `cluster delete`, and an
  `TopicObservationUnobservable` result is always a refusal.

**Coverage and Completion** (§3.1 invariants 1 and 5) extend to topics without amendment: no prodbox
code path may create a topic without a registered exact coordinate, closed observe/ensure/destroy
programs, a durable cleanup obligation, and mandatory read-back evidence. The
private registry/program constructors provide the compiled guarantee. The `check-code` registry ↔
[`substrates.md` Resource Lifecycle Classes](../../DEVELOPMENT_PLAN/substrates.md#resource-lifecycle-classes)
parity scan covers topic rows as a cross-seam drift guard; it is not the source of the guarantee.

## 5. Retention and Offload Draw Down the Finite Budget

A topic's `RetentionPolicy` — how much backlog it keeps and when segments offload to object storage —
is **owned by** [tiered_storage_capacity_doctrine.md](tiered_storage_capacity_doctrine.md), which
holds the finite MinIO/storage budget. This doctrine only **consumes** it: a `LongLived` topic's
offloaded segments are a line item in that budget, so a topic's retention draws it down alongside
every other stored object.

The target consequence is structural at the topic-construction boundary rather than a runtime
broker check: a `ManagedTopic` admitted by that boundary carries a certified retention value whose
construction consumes the capacity doctrine's `storageFitsWithin` relation. An over-budget or
malformed retention policy therefore has no target inhabitant. The proof may be projected through
an executable authoring schema or built directly by a pure Haskell constructor; this doctrine owns
the invariant, not a particular artifact path. It does not restate the budget arithmetic; see the
capacity doctrine's `storageFitsWithin`.

**Current/target boundary.** This is a target capacity contract, not a current-source guarantee. No
Pulsar Dhall exists in the repository, and the current `RetentionPolicy` exposes raw `Int` fields;
nothing binds those fields to `storageFitsWithin` in `dhall/capacity/Schema.dhall` or the Haskell
capacity layer. The current source therefore provides neither a Ring-1 nor a proof-carrying Haskell
unrepresentability guarantee for topic retention. This doctrine states the invariant and its honest
verification boundary without naming a future file or implementation owner. Implementation and
migration status remain plan-owned.

## 6. Illegal Topic States Are Unrepresentable

The table distinguishes the current topic-name boundary from target lifecycle and capacity
contracts. Implementation status remains plan-owned; the labels prevent a target type shape from
being mistaken for current-revision proof. This follows
[chaos_hardening_doctrine.md § 22](./chaos_hardening_doctrine.md#22-what-a-ring-2-gate-does-and-does-not-prove): a claim of unrepresentability
without its region is a claim about a different set of files than the reader will assume.

| Illegal state | Rejected by |
|---|---|
| A topic named by a literal string | **Current source boundary** — `TopicName` has no exported constructor; only `topicFor` ([§2](#2-topic-names-come-only-from-the-topic-algebra)) builds one |
| A topic prodbox can create with no exact observer or destroy/read-back program | **Target contract** — private registry/program constructors make the state unconstructible; the `check-code` registry ↔ `substrates.md` parity scan guards cross-seam drift (Coverage, §3.1 invariant 1) |
| A desired-absence decision silently passing on an unreachable broker | **Target contract** — the total exact-observation decision maps `TopicObservationUnobservable` to refusal (Soundness, §3.1 invariant 2) |
| Retention/offload exceeding the storage budget | **Target capacity contract, not current source** — a proof-carrying topic constructor consumes `storageFitsWithin`; the current raw `RetentionPolicy` fields carry no such proof ([§5](#5-retention-and-offload-draw-down-the-finite-budget)) |
| Malformed retention (for example, a negative byte ceiling) | **Target capacity contract, not current source** — the proof-carrying topic constructor admits only well-formed retention; the current raw `Int` fields do not make malformed values unrepresentable |

## 7. Status Ownership

Implementation, migration, validation closure, and qualification status live only in the
[Development Plan](../../DEVELOPMENT_PLAN/README.md#resume-here). This doctrine owns the
current-source correspondence and target invariant boundaries above, not a sprint ledger. It does
not reserve a schema artifact or assign schema implementation ownership.

## Intent Ownership

This doctrine owns "a Pulsar topic is a managed resource" intention.

- Owned statement: a Pulsar topic is a first-class registered managed resource — a typed exhaustive
  broker observation with partial/unobservable arms, closed idempotent ensure/destroy program tags,
  an existing `LifecycleClass`, and a name only the topic algebra can produce — reconciled through
  the [§3.1](lifecycle_reconciliation_doctrine.md#31-the-managed-resource-registry-and-exact-observation-boundary)
  registry, with retention drawn from the finite storage budget.
- Linked dependents: `src/Prodbox/Pulsar/Topic.hs` (opaque topic-algebra mirror),
  `src/Prodbox/Pulsar/TopicResidue.hs` (`ManagedTopic`, `TopicResidueStatus`, `topicDiscover`,
  `ensureTopic`, `deleteTopic`, and the projection), `src/Prodbox/Pulsar/Admin.hs` (broker-backed
  admin adapter), `src/Prodbox/Pulsar/Client.hs` (broker transport boundary),
  `src/Prodbox/Lifecycle/ResourceClass.hs` (topic-family class facts), and
  `src/Prodbox/Lifecycle/ResourceRegistry.hs` (topic managed-resource adapter).

## Cross-References

- [lifecycle_reconciliation_doctrine.md § 3.1](lifecycle_reconciliation_doctrine.md#31-the-managed-resource-registry-and-exact-observation-boundary) — the managed-resource registry this doctrine plugs into
- [pulsar_messaging_doctrine.md](pulsar_messaging_doctrine.md) — the topic algebra (`topicFor`) that owns topic names
- [tiered_storage_capacity_doctrine.md](tiered_storage_capacity_doctrine.md) — the finite storage budget and `RetentionPolicy` this doctrine consumes
- [storage_lifecycle_doctrine.md](storage_lifecycle_doctrine.md) — the retained MinIO storage that offloaded segments occupy
- [pure_fp_standards.md](pure_fp_standards.md) — ADTs over strings, exhaustive matching, Plan/Apply
- [README.md](README.md) — engineering doctrine index
- [../../DEVELOPMENT_PLAN/README.md](../../DEVELOPMENT_PLAN/README.md#resume-here) — implementation and migration status
