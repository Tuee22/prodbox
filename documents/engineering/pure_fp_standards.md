# Pure Functional Programming Standards

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: README.md, AGENTS.md, CLAUDE.md,
documents/engineering/README.md, documents/engineering/code_quality.md,
documents/engineering/dependency_management.md,
documents/engineering/distributed_gateway_architecture.md,
documents/engineering/effect_interpreter.md,
documents/engineering/lifecycle_control_plane_architecture.md,
documents/engineering/lifecycle_reconciliation_doctrine.md,
documents/engineering/refactoring_patterns.md,
documents/engineering/unit_testing_policy.md,
documents/engineering/pulsar_messaging_doctrine.md,
documents/engineering/resource_scaling_doctrine.md,
documents/engineering/pulsar_topic_lifecycle_doctrine.md,
documents/engineering/tiered_storage_capacity_doctrine.md,
documents/engineering/host_platform_doctrine.md,
documents/engineering/cluster_topology_doctrine.md,
documents/engineering/test_topology_doctrine.md,
documents/engineering/bootstrap_readiness_doctrine.md,
DEVELOPMENT_PLAN/phase-1-runtime-cli-aws-foundations.md,
DEVELOPMENT_PLAN/phase-4-lifecycle-canonical-paths.md
**Generated sections**: none

> **Purpose**: Define the repository-wide Haskell rules for pure planning, operation-indexed
> programs, external-state projection, deterministic evolution, and explicit effect boundaries.

The process topology and concrete capability algebra of the lifecycle redesign are owned by
[Lifecycle Control-Plane Architecture](./lifecycle_control_plane_architecture.md). This document
owns the generic functional rules those modules apply. Implementation status is owned only by the
[Development Plan](../../DEVELOPMENT_PLAN/README.md).

## 1. Boundary Model

### 1.1 Pure by default

Ordinary repository code is pure by default.

- Parsing, normalization, rendering, validation, planning, classification, `decide`, and `evolve`
  return values.
- Domain modules describe requests, observations, plans, decisions, events, and results.
- Effectful work belongs at command, daemon-resource, or interpreter boundaries.
- Mutable cells, sockets, clocks, queues, sessions, and processes never leak into a pure API.

Typical pure surfaces include settings validation, capability and component-graph construction,
resource algebra, lifecycle decision tables, event folds, renderers, and protocol codecs. Typical
boundaries include `Prodbox.Native`, CLI runners, `Subprocess`, HTTP/Vault/object-store adapters,
daemon actor loops, and `EffectInterpreter`.

### 1.2 Compute first, interpret second

Pure code produces a value before the boundary performs work:

```haskell
-- Example: pure command rendering.
renderKubectlWaitArgs :: Namespace -> [String]
renderKubectlWaitArgs namespace =
  [ "wait"
  , "--namespace"
  , renderNamespace namespace
  , "--for=condition=Ready"
  , "pod"
  , "--all"
  , "--timeout=300s"
  ]
```

The interpreter receives validated input and translates every external result back into a typed
observation or failure. It does not contain a second copy of domain decisions.

### 1.3 Programs are data

When operations have different legal inputs or results, represent them with a result-indexed GADT
instead of callbacks or string opcodes:

```haskell
-- Example: target shape; topology-specific constructors live in the linked control-plane SSoT.
data StoreProgram result where
  ObserveVersioned :: ObjectKey -> StoreProgram ObjectObservation
  PutIfVersion
    :: ObjectKey
    -> ObjectVersion
    -> ByteString
    -> StoreProgram ConditionalWriteResult
```

The interpreter is separate:

```haskell
runStoreProgram
  :: Monad m
  => StoreClient m
  -> Deadline
  -> StoreProgram result
  -> m (Either StoreFailure result)
```

This indexes operation legality. It does not prove that an external write happened; the typed
result and subsequent authoritative observation supply that evidence.

Forbidden program shapes include:

- a domain value storing `IO`, `m a`, or an arbitrary callback and labelling it as a stronger
  capability;
- a probe endpoint passed separately from the execution reference;
- a free-form operation name interpreted by string comparison; and
- a program whose interpreter may execute effects not represented by its constructors.

### 1.4 One typed model, many generated projections

A contract that crosses a compilation or serialization boundary — a chart YAML value, a Dhall
mirror, an HTTP route path, a probe endpoint, an object name — is single-sourced in one compiled
value and generated outward. The server dispatcher, client URL construction, chart probe and
statics rendering, and response goldens are projections of that value, not independent authors of
it. Where a consumer cannot yet be generated, a seconds-fast conformance check proves the
hand-authored copy equal to the compiled source before any cluster work runs; those suites belong
to the conformance tier of the [Unit Testing Policy](./unit_testing_policy.md).

An invariant that exists only as prose is a defect. A comment asserting that two artifacts agree,
a substring lint coupling a server route table to a chart probe path, or a hand-maintained mirror
of a compiled registry provides no proof and drifts silently; each is replaced by generation from
the single typed model or by a conformance check that fails the canonical quality gate.

## 2. Domain Modeling

### 2.1 Prefer ADTs over strings

Closed control-flow sets use explicit ADTs:

```haskell
-- Example: closed lifecycle command set.
data LifecycleAction
  = LifecycleInstall
  | LifecycleDelete ConfirmedDelete
  | LifecycleStatus
  deriving (Eq, Show)
```

Parse external text once, validate it, and operate on typed values. Use smart constructors for
identities, coordinates, byte/queue bounds, generations, epochs, fences, and deadlines.

### 2.2 Pattern match exhaustively

Handle every supported constructor explicitly. Catch-all branches over a closed ADT are forbidden
unless the fallback itself is a deliberate part of the public compatibility contract.

```haskell
renderLifecycleAction :: LifecycleAction -> Text
renderLifecycleAction action =
  case action of
    LifecycleInstall -> "install"
    LifecycleDelete _ -> "delete"
    LifecycleStatus -> "status"
```

### 2.3 Validate at decode boundaries

- Dhall decoding produces typed settings and then validates cross-field invariants.
- Text, JSON, CBOR, HTTP, and subprocess output are decoded once into typed observations.
- Execution receives validated identities and coordinates rather than checking raw strings again.
- Invalid, corrupt, missing, and unobservable are distinct when they imply different decisions.

### 2.4 Durability-indexed coordinates

When stored objects outlive different scopes — a chart release, the cluster, the fleet — the
lifetime class is a phantom index on both the storage coordinate and the adapter that reaches it:

```haskell
-- Example: lifetime index shared by coordinate and adapter; the exemplar is `StoreLifetime`.
data StoreLifetime = ChartLifetime | ClusterRetained | CrossClusterDurable

putIfVersion
  :: StoreAdapter lifetime m
  -> ObjectCoordinate lifetime
  -> ObjectVersion
  -> ByteString
  -> m (Either StoreFailure ConditionalWriteResult)
```

Smart constructors partition the object namespace by lifetime, so one coordinate cannot be minted
in two classes. An adapter carries the lifetime it honestly provides: a transport that dies with a
chart release is `ChartLifetime`, and storing retained-or-stronger state through it is a type
error rather than a runtime review finding. The concrete instance indexes the Model-B object
coordinates and CAS adapters; the retained-custody topology is owned by
[Lifecycle Control-Plane Architecture](./lifecycle_control_plane_architecture.md), and
implementation is owned by the [Development Plan](../../DEVELOPMENT_PLAN/README.md)
(Sprint `4.51`).

> **Implementation status (2026-07-14, Sprint `4.51` Increment A)**: the phantom index landed on the
> real `Prodbox.Lifecycle.CheckpointAuthority` Model-B types (`ModelBObjectCoordinate l`,
> `ModelBCasRequest l value`, `ModelBCasAdapter l m value`) with a `nominal` role and the
> full-name-tagging constructors `mkClusterRetainedCoordinate` / `mkChartLifetimeCoordinate` /
> `mkCrossClusterDurableCoordinate`. One refinement over the sketch above: a **lease guard is not
> lifetime-indexed** — a lease is always retained, so `ModelBLeaseGuard`'s coordinate is
> monomorphically `'ClusterRetained'`, which lets a `'ChartLifetime'` object be guarded by a retained
> lease under the request's single `l`. The gateway transport is still polymorphic in `l`;
> retyping it to `'ChartLifetime'`-only and adding the host-direct `'ClusterRetained'` adapter (so
> the "type error, not review finding" property holds in production) is Increment B.

## 3. State, Decisions, and Evolution

### 3.1 No hidden mutable control flow

Planning does not depend on ambient mutable state. Pass observations, current projection, command,
policy, and time explicitly. Return a decision, event set, and next state explicitly.

### 3.2 Mutable cells are boundary-only

Mutable references, bounded queues, session caches, handles, and actor mailboxes are permitted only
in the boundary module that owns the effect. Convert callback/library output to typed values at
that boundary. A pure helper must not read a `TVar`, clock, environment variable, file, or socket.

### 3.3 External authority uses `decide` and `evolve`

Externally durable or replicated state is a flat exhaustive ADT folded by total pure functions:

```haskell
-- Example: generic external-authority shape.
decide
  :: AuthorityState
  -> AuthorityCommand
  -> Either AuthorityRefusal (NonEmpty AuthorityEvent)

evolve :: AuthorityState -> AuthorityEvent -> AuthorityState
```

Required laws:

- deterministic replay: the same initial state and events produce the same state;
- exhaustive commands/events: every constructor has an explicit arm;
- idempotency: duplicate operation IDs, fences, revisions, or generations have a defined result;
- monotonic authority: stale epochs, fences, revisions, and generations cannot advance state;
- bounded projection: maps, queues, journals, outboxes, and retained histories have validated
  limits; and
- ambiguity preservation: applied-but-response-lost is represented as an observable nonterminal
  state, not guessed as success or failure.

The effect interpreter follows `observe -> decide -> CAS/effect -> re-observe`. A CAS conflict
causes fresh observation and re-decision. It never retries an old decision against new state.

Retained operator-material custody is a mandatory instance of this rule. Its
`RetainedMaterialSchema` is the closed SMTP/EAB sum, its custody observations are the flat
present/positively-absent/corrupt/digest-mismatch/unobservable ADT, and pending seal, current source,
per-target delivery, supersession, retention, and tombstone promotion occur only through total
Authority `decide`/`evolve` commands and events. A Transit/Vault/Agent interpreter returns typed
read-back evidence; it cannot promote durable state from effectful control flow. The exact indexed
programs and ledger are owned by
[Lifecycle Control-Plane Architecture §5.5](./lifecycle_control_plane_architecture.md#55-retained-operator-material-custody).

### 3.4 Always-run work uses a DAG result fold

Fail-fast sequencing is appropriate for mutation steps whose prerequisites failed. It is not
appropriate for cleanup. A cleanup plan is a pure DAG with `RequiresAttempt` and
`RequiresSuccess` edges; its interpreter runs every independent ready node and aggregates all
outcomes without replacing the original failure.

## 4. Error Handling

### 4.1 Ordinary failures use explicit results

Expected failures return structured results rather than exceptions. Domain errors use closed ADTs
where callers make decisions from the constructor. Preserve authority, operation, stage, deadline,
and observation detail needed for recovery.

Exceptions remain appropriate for asynchronous cancellation and truly unexpected library faults at
the boundary. Catch them once, preserve asynchronous cancellation semantics, and convert supported
failures into typed values.

### 4.2 Avoid partial functions

Supported-path logic must not rely on `head`, `tail`, `init`, `(!!)`, `fromJust`, unchecked `read`,
or non-exhaustive matches. Prefer `NonEmpty`, bounded collections, total parsing, and smart
constructors.

## 5. Collection and Control-Flow Style

### 5.1 Prefer combinators and folds

Use `map`/`fmap`, `filter`, strict folds, `traverse`, and comprehensions where they expose data flow
clearly. State and event folds must state their ordering and idempotency assumptions.

### 5.2 Separate selection, ordering, and interpretation

For prerequisite, reconcile, workflow, or cleanup work:

1. derive the selected nodes and typed inputs purely;
2. validate and derive order purely;
3. render or inspect that plan without effects; and
4. interpret it at the boundary.

The same compiled value drives narration and execution. A parallel hand-maintained order or hidden
preparation sequence is forbidden.

## 6. External-System Boundaries

### 6.1 Render subprocesses as data

Subprocess helpers assemble `Subprocess`/`CommandSpec` values with explicit argv, environment, and
working directory. Shell strings and ambient credential discovery are forbidden. Parse output into
typed results at one boundary.

### 6.2 Prefer native managed clients on hot paths

High-frequency or authority-critical operations use managed in-process clients with pooled
connections and explicit sessions. Starting a heavyweight CLI, creating temporary files, logging
in, or rebuilding an HTTP manager per request is not an acceptable hot-path interpreter.

Provider tools that necessarily remain subprocesses run behind a separately resourced typed worker
and a durable intent/fence. They never write authority state directly.

### 6.3 One absolute deadline

A boundary creates one monotonic absolute deadline. Admission, queue wait, authentication refresh,
external I/O, read-back, result persistence, serialization, retry delay, and cancellation consume
its remaining budget. A nested interpreter must not reset that clock with another relative timeout.

```haskell
-- Example: total remaining-budget observation.
data DeadlineObservation
  = DeadlineOpen RemainingDuration
  | DeadlineExpired
```

Retry is legal only for a classified transient failure, an idempotent or durably identified
operation, and a next attempt that fits in the original deadline. Queue saturation is a typed
admission refusal, not an instruction to accumulate waiters.

### 6.4 At-least-once processing

Durable work is at least once. Commit an operation or outbox intent before executing its external
effect; identify it by a stable operation/action key; make the handler idempotent; and acknowledge
completion only after authoritative read-back. A lost response is resolved by observing the
operation ID.

Gateway peer gossip remains a bounded anti-entropy protocol, not a durable work queue. It shares
idempotent fold requirements but uses the protocol defined by
[Distributed Gateway Architecture](./distributed_gateway_architecture.md).

## GADT-Indexed State Machines

Use GADTs for either:

1. **operation legality**, where constructors determine legal input/result types; or
2. **authoritative in-process state**, where this process is the sole writer of the indexed
   transition, such as an actor's accepting/draining/stopped mailbox lifecycle.

Do not use a GADT to claim that externally authoritative or replicated state changed. External
readiness, leases, provider state, target generations, durable operation records, gateway
ownership, and residue are flat exhaustive ADTs computed by pure projection/fold.

Runtime discovery uses an existential wrapper with a singleton operation witness:

```haskell
-- Example: existential capability requirement.
data SomeCapabilityRequirement where
  SomeCapabilityRequirement
    :: SCapability kind
    -> CapabilityRequirement kind
    -> SomeCapabilityRequirement
```

The parameterized requirement contains the exact operation coordinate. The resolved opaque
reference owns that coordinate once; program payload does not duplicate it, and admission binds
both the reference digest and canonical payload digest. The canonical fields and constructors are
owned by [Lifecycle Control-Plane Architecture §3](./lifecycle_control_plane_architecture.md#3-pure-capability-algebra).

The former `ComponentReadinessTarget` pattern, which stored an arbitrary one-shot `IO` action next
to a component/backend label, is superseded. It could reject a constructor mismatch but could not
prove that the action used the named endpoint, operation, or authority. The replacement is an
operation-indexed program plus an opaque same-reference interpreter, owned by
[Lifecycle Control-Plane Architecture](./lifecycle_control_plane_architecture.md).

## Plan / Apply

Every one-shot command that performs meaningful mutation splits into a pure build and an effectful
apply:

```haskell
build :: Inputs -> Either AppError Plan
apply :: Env -> Plan -> IO ExitCode
```

`--dry-run` renders the exact plan without applying it, and `--plan-file` writes that deterministic
representation. `apply` may mutate only what the plan describes.

For an externally authoritative reconciler, reconnaissance supplies separate exhaustive
observations, the pure planner produces explicit actions/refusals, and the interpreter re-observes
postconditions. `Unobservable` never becomes `Absent`, `Missing`, or `Ready`.

Long-running work uses Plan/Apply at submission time but does not keep an HTTP call or host process
open for the whole workflow. The plan submits an idempotent operation request; the authority
durably admits and journals it; workers execute committed intents; and the client observes the
operation ID until a terminal projection. Recovery is re-observation and `decide`/`evolve`, not a
caller repeating an unknowable mutation.

## 9. Testing Implications

Pure-functional structure determines the proof layers:

- unit tables cover every ADT constructor and refusal;
- property tests cover codecs, replay, idempotency, monotonic epochs/fences/generations, bounds,
  deadline monotonicity, and cleanup scheduling;
- deterministic concurrency simulation covers actor interleavings, cancellation, saturation,
  response loss, and restart at every durable boundary;
- production-adapter composition tests use the real binary and native MinIO/Vault clients;
- load tests exercise authored background rate plus burst under exact cgroups and record CPU
  throttling, queue wait, deadline misses, and latency; and
- chaos tests terminate or isolate each process at every durable transition and prove resume,
  typed refusal, and residue cleanup.

Mocks and fakes exist only at interpreter boundaries. A fake trace does not qualify the production
adapter composition it replaces. Deployment qualification is governed by
[Development Plan Standard P](../../DEVELOPMENT_PLAN/development_plan_standards.md#p-deployment-qualification-and-counterexample-closure).

## 10. Review Checklist

Before closing a change, confirm:

- closed control flow uses ADTs and exhaustive matches;
- capability programs are data and contain no arbitrary `IO` callbacks;
- external state uses flat observations plus total `decide`/`evolve` folds;
- authority identifiers, scopes, epochs, fences, and generations are validated types;
- one absolute deadline reaches every nested boundary;
- queues and retained projections are bounded;
- mutable resources remain inside their owning interpreter;
- hot paths use managed native clients rather than heavyweight subprocesses;
- cleanup is registered before mutation and independent cleanup cannot short-circuit; and
- the appropriate pure, simulation, composition, load, chaos, and deployment proofs exist.

## Intent Ownership

This document owns generic pure-FP and interpreter-boundary doctrine. It does not own component
topology, lifecycle business semantics, exact capacity thresholds, or implementation status.

## Cross-References

- [Lifecycle Control-Plane Architecture](./lifecycle_control_plane_architecture.md)
- [Bootstrap Readiness Doctrine](./bootstrap_readiness_doctrine.md)
- [Lifecycle Reconciliation Doctrine](./lifecycle_reconciliation_doctrine.md)
- [Effect Interpreter Runtime Contract](./effect_interpreter.md)
- [Effectful DAG Architecture](./effectful_dag_architecture.md)
- [Resource Scaling Doctrine](./resource_scaling_doctrine.md)
- [Unit Testing Policy](./unit_testing_policy.md)
- [Refactoring Patterns](./refactoring_patterns.md)
- [Development Plan](../../DEVELOPMENT_PLAN/README.md)
