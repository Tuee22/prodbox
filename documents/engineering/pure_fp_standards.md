# Pure Functional Programming Standards

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: README.md, AGENTS.md, CLAUDE.md, documents/engineering/README.md, documents/engineering/code_quality.md, documents/engineering/dependency_management.md, documents/engineering/distributed_gateway_architecture.md, documents/engineering/effect_interpreter.md, documents/engineering/lifecycle_reconciliation_doctrine.md, documents/engineering/refactoring_patterns.md, documents/engineering/unit_testing_policy.md, documents/engineering/pulsar_messaging_doctrine.md, documents/engineering/resource_scaling_doctrine.md, documents/engineering/pulsar_topic_lifecycle_doctrine.md, documents/engineering/tiered_storage_capacity_doctrine.md, documents/engineering/host_platform_doctrine.md, documents/engineering/cluster_topology_doctrine.md, documents/engineering/test_topology_doctrine.md, documents/engineering/bootstrap_readiness_doctrine.md, DEVELOPMENT_PLAN/phase-1-runtime-cli-aws-foundations.md, DEVELOPMENT_PLAN/phase-4-lifecycle-canonical-paths.md
**Generated sections**: none

> **Purpose**: Define the Haskell coding standards for `prodbox` so pure planning logic,
> structured domain modeling, and explicit impurity boundaries stay consistent across the
> repository.

## 1. Boundary Model

### 1.1 Pure by Default

Ordinary repository code is pure by default.

- Parsing, normalization, rendering, validation, and planning helpers return values.
- Domain modules describe what should happen; they do not perform effects while deciding it.
- Effectful work belongs at command or interpreter boundaries only.

Typical pure surfaces in this repository include:

- `src/Prodbox/Settings.hs` validation helpers
- `src/Prodbox/ContainerImage.hs` image-reference normalization and mapping
- `src/Prodbox/Effect.hs`, `src/Prodbox/EffectDAG.hs`, and `src/Prodbox/Prerequisite.hs`
- chart-plan, storage-path, and output-rendering helpers

Typical impure surfaces include:

- `src/Prodbox/Native.hs`
- `src/Prodbox/CLI/*`
- `src/Prodbox/Subprocess.hs`
- `src/Prodbox/EffectInterpreter.hs`
- runtime loops such as `src/Prodbox/Gateway/Daemon.hs`

### 1.2 Boundary Rule

Pure code computes arguments, plans, or typed values first. The boundary layer executes them
afterward.

```haskell
renderKubectlWaitArgs :: String -> [String]
renderKubectlWaitArgs namespace =
    ["wait", "--namespace", namespace, "--for=condition=Ready", "pod", "--all", "--timeout=300s"]
```

```haskell
runKubectlWait :: FilePath -> String -> IO ExitCode
runKubectlWait repoRoot namespace =
    runCommand
        CommandSpec
            { commandPath = "kubectl",
              commandArguments = renderKubectlWaitArgs namespace,
              commandEnvironment = Nothing,
              commandWorkingDirectory = Just repoRoot
            }
```

## 2. Domain Modeling

### 2.1 Prefer ADTs Over Strings

Closed control-flow sets must be represented as explicit algebraic data types.

```haskell
data LifecycleAction
    = LifecycleInstall
    | LifecycleDelete ConfirmedDelete
    | LifecycleStatus
    deriving (Eq, Show)
```

- Do not route major control flow through free-form `String` flags.
- Parse external text once, then operate on typed values.
- Use records when named fields improve clarity.

For the lifecycle-command predicate / reconciler / phase-ADT layering that
extends this pattern across `prodbox cluster delete`, `prodbox aws teardown`,
`prodbox aws stack <stack> destroy`, and `prodbox nuke`, see
[lifecycle_reconciliation_doctrine.md](lifecycle_reconciliation_doctrine.md).
That doctrine's managed-resource registry (§3.1) is the data-oriented
endpoint of this discipline: the registry is pure data (a `[ManagedResource]`
list), and the `reconcileAbsent` reconciler is "data in, data out" — chosen
deliberately over a global state machine, which would couple to external state
that cannot be refreshed transactionally.

### 2.2 Pattern Match Exhaustively

Handle every supported constructor explicitly.

```haskell
renderLifecycleAction :: LifecycleAction -> String
renderLifecycleAction action =
    case action of
        LifecycleInstall -> "install"
        LifecycleDelete _ -> "delete"
        LifecycleStatus -> "status"
```

- Avoid catch-all branches for closed ADTs when an explicit match is practical.
- When a match must remain open-ended, document why the fallback is acceptable.

### 2.3 Validate at Decode Boundaries

Decode and validation happen before execution.

- Dhall decoding produces typed settings.
- Text parsing for image references, hostnames, IP addresses, and command arguments should fail
  early with structured error text.
- Execution layers should receive already-validated inputs whenever possible.

## 3. State and Mutation

### 3.1 No Hidden Mutable Control Flow

Ordinary planning logic should not depend on hidden mutable state.

- Prefer immutable values, record updates, recursion, and folds.
- Pass required inputs explicitly.
- Keep state transitions visible in function arguments and return values.

### 3.2 Mutable Cells Are Boundary-Only

Mutable references, handles, sockets, or background loops are allowed only where the repository
must coordinate real effects.

- Keep them local to the boundary module that owns the effect.
- Do not leak mutable implementation details into pure helper APIs.
- Convert mutable or callback-driven libraries back into typed values as soon as possible.

## 4. Error Handling

### 4.1 Ordinary Failures Use Explicit Results

Expected failures should return structured results rather than relying on exceptions for control
flow.

- Prefer `Either String a`, `Maybe a`, or repository result types for ordinary validation and
  planning failures.
- Convert library exceptions at the boundary into explicit failure values when they are part of
  supported behavior.

```haskell
parseRequiredPort :: String -> Either String Int
parseRequiredPort raw =
    case readMaybe raw of
        Just port | port >= 1 && port <= 65535 -> Right port
        _ -> Left ("invalid port: " ++ raw)
```

### 4.2 Avoid Partial Functions

Do not rely on partial functions in supported-path logic.

- Avoid `head`, `tail`, `init`, `(!!)`, `fromJust`, and unchecked `read`.
- Prefer total parsing, `NonEmpty`, explicit pattern matches, or safe helpers.

## 5. Collection and Control-Flow Style

### 5.1 Prefer Combinators and Folds

Use standard functional combinators to make data flow explicit.

- `map` or `fmap` for transformation
- `filter` for selection
- `foldl'` or `foldr` for accumulation
- `traverse` for effectful iteration with explicit result collection
- list comprehensions when they are clearer than nested combinators

```haskell
renderImageTags :: [ImageRef] -> [String]
renderImageTags refs =
    [renderImageRef ref | ref <- refs, imageTag ref /= ""]
```

### 5.2 Separate Selection From Execution Order

When a command has prerequisite or staged work:

1. derive the ordered or grouped plan in pure code
2. execute that plan in the boundary layer
3. stop on explicit failure, preserving the root cause

This is the same doctrine used by the effect DAG and test-validation runtimes.

## 6. Subprocess and External-System Boundaries

### 6.1 Render Commands as Data

Subprocess helpers should assemble commands as structured values instead of concatenated shell
strings.

- Use `CommandSpec` and explicit argument vectors.
- Keep environment overlays explicit.
- Parse stdout or stderr into typed results instead of spreading ad-hoc string checks across the
  codebase.

### 6.2 Keep External I/O Local

Filesystem reads, environment reads, network calls, Kubernetes calls, Docker calls, and AWS CLI
calls belong in the narrowest boundary that can own them.

- A planner may decide that registry reconciliation is required.
- The boundary layer performs `docker`, `kubectl`, `helm`, `aws`, or `curl`.
- Output is translated back into typed success or failure for the caller.

## 6.3 At-Least-Once Event Processing

Daemons that consume durable work events (future workload event surfaces and workers) consume the
canonical at-least-once pattern from
[At-Least-Once Event
Processing](./streaming_doctrine.md) exposed by
`src/Prodbox/Daemon/Events.hs` (introduced by Sprint 2.16 in
[../../DEVELOPMENT_PLAN/phase-2-gateway-dns.md](../../DEVELOPMENT_PLAN/phase-2-gateway-dns.md)).

The module provides `StoredEvent`, `recordEvent`, `markEventProcessed`,
`fetchUnprocessedEvents`, and the `EventHandler` newtype with the idempotency precondition
encoded in its haddock. Handlers must be idempotent: events may be delivered multiple times
(process crash before ack, network partition during ack, explicit replay). Idempotency
strategies include database constraints, check-then-act with a dedup key, or pure
projections of the event payload.

Pure planning logic must not duplicate the at-least-once pattern; consume the canonical module
instead. Gateway peer gossip is a different, non-durable coordination protocol documented in
[Distributed Gateway Architecture](./distributed_gateway_architecture.md#721-at-least-once-correspondence):
it shares the idempotency and ordering discipline but does not need durable `processed_at`
tracking because peers fold bounded cursor deltas or bounded semantic snapshots rather than
acknowledging a work queue. Complete process-lifetime batch replication is forbidden and is not an
at-least-once requirement. Sprint `2.31` landed this bounded shape; repair uses a signed
per-emitter semantic checkpoint plus a bounded contiguous suffix.

## 7. Testing Implications

Pure-functional structure is not stylistic only; it determines how code is tested.

- Pure helpers are tested directly in `test/unit/Main.hs`.
- Built-frontend command behavior is tested in `test/integration/Main.hs` through
  `test/integration/CliSuite.hs` and `test/integration/EnvSuite.hs`.
- Real infrastructure-backed behavior is tested through named `prodbox test integration ...`
  validations.
- Mocks belong at subprocess or interpreter boundaries, not inside pure planners.

A concrete payoff of the boundary model (§6): keep subprocess-output *classification* pure so
it is unit-tested against captured `ProcessOutput` fixtures with no process spawned and no
mock. The boundary runs the subprocess and hands back a typed `ProcessOutput`; a pure
classifier maps that value onto a typed result. The classifier is the unit under test:

```haskell
-- pure: no IO, no mock — the unit under test
classifyServiceError :: ProcessOutput -> Maybe ServiceError

-- in test/unit/Main.hs: feed a captured ProcessOutput, assert the typed verdict
testRedisThrottleIsRetryable :: TestTree
testRedisThrottleIsRetryable =
    testCase "OOM stderr classifies as a retryable ServiceError" $
        classifyServiceError oomFixture @?= Just RedisOutOfMemory
```

The effectful boundary (`runRedis :: [String] -> m (Either ServiceError ProcessOutput)`) is
exercised separately at the interpreter boundary; the classification logic that decides
*whether a failure is retryable* never needs a process to test. See the typed-`ServiceError`
classification contract in
[haskell_code_guide.md](./haskell_code_guide.md) (the target shape Sprint 1.30 moves the code
toward).

## 8. Review Checklist

Before closing a change, confirm:

- control flow is driven by explicit ADTs rather than ad-hoc strings when the set is closed
- parsing and validation happen before execution
- ordinary failures return explicit values rather than using exceptions for flow control
- partial functions are absent from supported-path logic
- subprocess and I/O work stay in command, interpreter, or runtime-boundary modules
- pure helpers are small enough to unit test without boundary mocks

## Intent Ownership

This SSoT co-owns repository coding-style doctrine.

- Owned statement: ordinary `prodbox` logic is pure by default, and real effects execute only at
  explicit command or interpreter boundaries.
- Linked dependents: `src/Prodbox/Settings.hs`, `src/Prodbox/ContainerImage.hs`,
  `src/Prodbox/EffectInterpreter.hs`, `src/Prodbox/Subprocess.hs`, `src/Prodbox/TestRunner.hs`,
  `test/unit/Main.hs`.

## GADT-Indexed State Machines

State machines whose transitions are **authoritative in-process** — where this process is the
sole writer and a transition is a fact only once it has happened here — and that have more than
two states must use GADTs with phantom type parameters to encode valid transitions at the type
level. Invalid transitions become compile errors, not runtime errors.

The GADT mandate is scoped to in-process authority. **Externally-authoritative or
reconciled state** does not use a GADT-indexed command type: when the authoritative state
lives outside this process — derived by folding a replicated semantic projection, reconstructed from a
remote system's observed state, or otherwise reconciled rather than commanded — model it as a
flat **exhaustive ADT** computed by a pure projection. The gateway ownership model is the
canonical example: ownership is a `Disposition` projection folded from bounded signed semantic
state, not a command sequence this process authors, so it is an exhaustive ADT rather than
a GADT (see
[distributed_gateway_architecture.md](./distributed_gateway_architecture.md)). There is no valid
in-process "transition" to encode at the type level, because no transition originates here; the
replicated observation is the source of truth and the projection is recomputed, not stepped. Cluster **readiness** is a
second reference example: it is *observed*, not commanded, so Sprint `1.59`'s
`ReadinessObservation` (`ReadyObserved | NotReadyYet | Unreachable`) and `ReadinessProbeResult`
(`ReadinessProbeReady | ReadinessProbePending`) are flat exhaustive ADTs — never GADTs — under the
"readiness is a projection" rule that
[bootstrap_readiness_doctrine.md](./bootstrap_readiness_doctrine.md) Statement 3 cites, and the bring-up
inverse-polarity twin of the `ResidueStatus` teardown projection. `ComponentReadinessTarget` is also
a flat sum: each constructor pairs typed component/backend identity with one caller-injected
one-shot action. The target carries behavior at the interpreter boundary without pretending the
process owns the external state or duplicating the caller's coordinates.

The component dependency graph follows the same external-observation rule. A graph node is a
declarative component/readiness fact, not a phantom lifecycle state. A bounded split is permitted
only when one real component has two distinct externally observable readiness cuts, and each split
node must carry exactly one `ReadinessProbe`; do not proliferate graph nodes into a general phase
machine. Sprints `1.58`/`1.59` are the reference shape: `ComponentClusterBase` carries
`ProbeServiceActive`; `ComponentVaultWorkload`
(`ProbeRolloutComplete`) precedes `ComponentGatewayDaemonPreVault` (`ProbeRolloutComplete`), and
both precede `ComponentVaultUnsealed` (`ProbeVaultUnsealed`) because supported root unseal is
daemon-mediated. The pre-Vault daemon and unsealed-Vault nodes then precede
`ComponentGatewayDaemonFull` (`ProbeBackendRoundTrip ComponentMinio`), whose dependency list also
contains a `BackendWriteEdge` to MinIO. These are flat graph
facts whose edges are pure data. They do not encode transitions or confer in-process authority over
Vault or the daemon's observed state.

The wait interpreter preserves this distinction. A target/probe type-shape mismatch is rejected
before polling or executing the incompatible action. A compatible action's authoritative pending
result becomes `NotReadyYet`; an observation error becomes `Unreachable`. Both remain bounded,
gate-closed `PollPending` readings. `PollFailed` is the generic poller's separate immediate
hard-error arm, not an alias for `Unreachable`. Only `ReadyObserved` opens readiness.

Sprint `5.16`'s landed runtime-stability classifier is a third external projection, not a stronger
readiness constructor. `Prodbox.Test.GatewayRuntimeStability` purely parses Pod, Event, and metrics
JSON into a flat exhaustive pod observation, then combines a run-wide absorbing outcome with a
consecutive-success window. Restart, OOM, failure-threshold high-water, and unobservable evidence
are absorbing. Warning pressure, Pending, and Pod UID replacement reset consecutive success; only
a gateway rollout present in the compiled restore/lifecycle plan may explicitly reset the whole
healthy-window baseline. No reset changes the absorbing result. The aggregate observation returns
stable, not-yet-stable, unhealthy, or unreachable, so a current Ready value cannot erase an
OOM/restart observed earlier in the run; see
[bootstrap_readiness_doctrine.md §2.1](./bootstrap_readiness_doctrine.md#21-dependency-readiness-vs-runtime-stability).

The interpreter preserves that pure/effect split with one concurrency-safe, run-scoped recorder.
A structured continuous observer and every explicit rollout-boundary/final sample serialize their
folds through the same observation lock and state cell. The explicit baseline is handed off only
after the continuous observer completes its first observation, so later suite work cannot create a
sampling gap. AWS supplies the observer a monitor-private EKS kubeconfig and an explicit
Vault-derived subprocess environment instead of mutating ambient process state. Its gateway
reconcile and point sample precede the handoff; SMTP synchronization and dependent chart
reconciles follow it. Only a compiled planned home/target gateway rollout may pause and drain the
observer; it resets only the healthy window, never the absorbing outcome. Each stability `kubectl`
read carries
`--request-timeout=5s` and is independently bounded by GNU `timeout` plus `System.Timeout`.

The separate `GatewayRuntimeRecreatedTarget` projection covers a whole observed-cluster
replacement such as `eks-volume-rebind`. Its interpreter pauses/drains, takes the pre-replacement
sample, resets only the healthy window, recreates the target through the canonical AWS
gateway/platform path where applicable, and requests a monitor-context refresh. The refresh
acknowledgement proves the worker has exited the old kubeconfig bracket and materialized a new one;
a foreground sample runs while still paused, then the monitor resumes. This effect choreography
does not alter the pure absorbing fold.

Runtime-memory planning demonstrates the boundary between a pure proof value and an external
observation. `Prodbox.Capacity.RuntimeMemory.validateRuntimeMemoryPlan` consumes positive byte-unit
inputs plus a finite child schedule and returns either a structured `RuntimeMemoryError` or an
opaque `RuntimeMemoryPlan`. The plan proves the nested heap/container inequalities, derives the GHC
RTS argv, and projects `container limit - safety margin` as a typed high-water comparison value.
It performs no IO and does not claim that the running process honored the plan.

`Prodbox.Capacity.Config.runtimeMemoryPlanForProfile` supplies the container limit from the matching
workload resource envelope, so validation cannot accidentally compare against a second authored
ceiling. `ChartPlatform` consumes only the validated plan when rendering gateway RTS arguments.
`Prodbox.Gateway.Bounds` consumes the plan to validate gateway state/transport limits, and
`Prodbox.Gateway.ChildSchedule` plus the daemon enforce the capacity-one child permit landed in
Sprint `2.31`. Sprint `5.16` landed the flat exhaustive external stability observation and the
effectful Kubernetes adapter, shared recorder, and continuous monitor in `Prodbox.TestValidation`.
Thresholds are projected from the validated runtime-memory plan, and log text remains
diagnostic-only. Neither external observation nor its effectful adapter is folded into the pure
planner. Post-refresh code-owned evidence is 17/17 focused unit tests, 2/2 built-frontend
`gateway-pods` fixtures (healthy and a background-only OOM retained through later healthy samples),
and 1494/1494 full unit tests, plus the exact post-refresh full CLI integration suite at 47/47.
`prodbox dev check` passes as the final repository closure gate. The live multi-peer substrate soak
remains a non-blocking Standard-O proof.

This carve-out does **not** relax the rest of the discipline. Externally-authoritative state
must still be a typed ADT, matched exhaustively (§2.1, §2.2), and must never be a raw `String`
or `Text` status field with string comparisons. The difference is only whether transitions are
encoded as GADT indices (in-process authority) or recomputed as a pure fold over the
authoritative replicated/external observation (external authority).

The prescribed shape for in-process authoritative state machines:

```haskell
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE StandaloneKindSignatures #-}

-- | Status indexed at the type level
data OrderStatus
    = Draft
    | Submitted
    | Approved
    | Fulfilled
    | Cancelled

-- | Singleton witnesses for runtime status discovery
data SOrderStatus (s :: OrderStatus) where
    SDraft :: SOrderStatus 'Draft
    SSubmitted :: SOrderStatus 'Submitted
    SApproved :: SOrderStatus 'Approved
    SFulfilled :: SOrderStatus 'Fulfilled
    SCancelled :: SOrderStatus 'Cancelled

-- | Commands indexed by input and output status
type OrderCmd :: OrderStatus -> OrderStatus -> Type -> Type
data OrderCmd (s :: OrderStatus) (s' :: OrderStatus) a where
    AddItem :: ItemId -> Quantity -> OrderCmd 'Draft 'Draft ()
    RemoveItem :: ItemId -> OrderCmd 'Draft 'Draft ()
    Submit :: OrderCmd 'Draft 'Submitted SubmissionReceipt
    Approve :: ApprovalNotes -> OrderCmd 'Submitted 'Approved ()
    Reject :: RejectionReason -> OrderCmd 'Submitted 'Cancelled ()
    Fulfill :: ShipmentInfo -> OrderCmd 'Approved 'Fulfilled TrackingNumber
    Cancel :: CancellationReason -> OrderCmd 'Draft 'Cancelled ()
```

The GADT indices track both the required input state (first parameter) and the resulting
output state (second parameter). The type system enforces that `Submit` can only be called
on a `Draft` order, `Approve` only on a `Submitted` order, and so on.

### Existential wrapping for runtime discovery

When loading state from a database, the status is unknown at compile time. Use existential
wrapping with singleton witnesses to recover type information:

```haskell
data SomeOrder where
    SomeOrder ::
        SOrderStatus s ->
        OrderHandle s ->
        SomeOrder

loadOrder :: Connection -> UUID -> IO (Either OrderError SomeOrder)
loadOrder conn orderId = do
    row <- queryOrderRow conn orderId
    pure $ case orderRowStatus row of
        "draft" -> Right (SomeOrder SDraft (mkHandle row))
        "submitted" -> Right (SomeOrder SSubmitted (mkHandle row))
        "approved" -> Right (SomeOrder SApproved (mkHandle row))
        "fulfilled" -> Right (SomeOrder SFulfilled (mkHandle row))
        "cancelled" -> Right (SomeOrder SCancelled (mkHandle row))
        unknown -> Left (UnknownStatus unknown)
```

Pattern matching on the singleton witness recovers the phantom type, enabling typed
operations on dynamically loaded values without unsafe casts.

**Forbidden patterns:**

- Runtime status enums with manual validation in command handlers.
- Status fields as `Text` or `String` with string comparisons — for both GADT-indexed and
  log-reconciled state.
- **In-process authoritative** state machines with more than two states that do not use GADT
  indexing. (Externally-authoritative / log-reconciled state is exempt from the GADT
  requirement but must still be an exhaustive ADT computed by a pure projection — see above.)
- Existential wrappers without singleton witnesses (losing type information).
- Modeling log-reconciled or externally-authoritative state as a GADT-indexed command type:
  there is no in-process transition to encode, so the GADT machinery is dead weight that
  implies an authority the process does not have. Use the flat exhaustive projection ADT.

> **Doctrine realignment**: This section's in-process/external authority split is the
> doctrine target for Sprint 1.32 (retire the un-adopted `src/Prodbox/StateMachine.hs` and its
> lone typecheck test, realign the GADT doctrine to the reconciled-projection reality). The
> gateway `Disposition` projection (an exhaustive ADT folded over bounded semantic replica state) is
> the landed reference shape for the externally-authoritative case. Sprint `2.31` replaced the
> former append-only projection with keyed bounded state without changing this flat-ADT rule.

## Plan / Apply

Every command that does meaningful work in the world splits into two phases:
a pure `build` function that produces a typed `Plan` ADT, and an effectful
`apply` function that executes the plan. The plan is a value — print it, diff
it, golden-test it, dry-run it. None of those operations require IO.

The standard shape:

```haskell
build :: Inputs -> Either AppError Plan      -- pure
apply :: Env    -> Plan -> IO ExitCode       -- effectful
```

`build` lives in `src/MyTool/...` and is total. `apply` lives in a command
runner and is the only place that touches the world.

A worked example for a small deploy command:

```haskell
data DeployPlan = DeployPlan
  { deployPlanPreChecks :: [Validation]   -- see Prerequisites as Typed Effects
  , deployPlanSteps     :: [Subprocess]   -- see Subprocesses as Typed Values
  }
  deriving stock (Eq, Show)

renderDeployPlan :: DeployPlan -> Text
buildDeployPlan  :: DeployInputs -> Either AppError DeployPlan
applyDeployPlan  :: Env -> DeployPlan -> IO ExitCode
```

Required flags on every Plan/Apply command:

- `--dry-run` prints the rendered plan and exits 0. The implementation is
  `build` followed by `renderPlan`; `apply` is never reached.
- `--plan-file <path>` writes the rendered plan to disk, enabling out-of-band
  review before apply.

Pair with golden tests: plans are deterministic Haskell values and are the
cleanest possible targets for `tasty-golden`. The **Golden Tests** category
in the testing doctrine should include `render <Plan>` for every Plan/Apply
command the tool publishes.

**Forbidden patterns:**

- Interleaving IO into `build`. Probing the filesystem, network, or env to
  decide what's in the plan defeats determinism. Probing belongs in a
  read-only reconnaissance phase whose typed outputs feed `build`.
- A Plan/Apply command without `--dry-run`. If the plan cannot be safely
  rendered without running it, the split has not actually been made.
- An `apply` that mutates state not described in the `Plan`. The plan is the
  full audit trail of what the command will do; out-of-band mutation is a
  correctness bug.
- Caching or memoizing `build` across invocations. It is cheap; if it is not,
  the inputs are wrong.

This section composes with two others:

- [Prerequisites as Typed Effects](./prerequisite_doctrine.md#prerequisites-as-typed-effects)
  runs before `apply`. A prerequisite failure aborts before any plan step
  executes.
- [Reconcilers](./cli_command_surface.md#reconcilers-idempotent-mutation-as-a-single-command)
  are a specialization: a reconciler is a Plan/Apply command whose `apply` is
  a no-op when current state already matches the plan's desired state.

For an externally authoritative desired-present reconciler, reconnaissance must preserve each
independent authority as its own flat exhaustive observation ADT. Resource presence and checkpoint
usability, for example, are not one Boolean: the pure planner consumes both observations, emits
explicit create/import/repair/refuse actions, the interpreter enacts them, and the authority is
re-observed afterward. `Unobservable` never becomes `Absent` or `Missing`, and no GADT claims that
an in-process constructor proves an external transition occurred. The canonical shape is owned by
[Lifecycle Reconciliation Doctrine §3.1](./lifecycle_reconciliation_doctrine.md#desired-present-reconciliation-for-long-lived-resources).

The repository implementation is `Prodbox.Lifecycle.ResidueStatus` plus
`Prodbox.Lifecycle.DesiredPresence`: its total planner names all six observable
presence × checkpoint actions (three absent/create cases and three present/import/reconcile/repair
cases), while either unobservable authority produces a structured refusal. The interpreter carries
the planned action as data, enacts it through injected hooks, and accepts success only after fresh
`PresencePresent` and `CheckpointValid` observations. Opaque Model-B CAS lives behind
`CheckpointAuthority` / `CheckpointAuthorityStore`; an object-store version is a conditional-write
precondition, not proof of a lifecycle transition and not a fencing token.

Sprint `4.47` carries the same rule through the retained SES transaction. `Lease` encodes active
and released authority state as bounded CBOR projections; acquisition returns both the new grant
and any predecessor recovery evidence, so a successor cannot erase the expiry/release time that
anchors provider and target-write grace. A released v2 projection preserves that predecessor;
legacy released state without a safe recovery anchor fails closed. `LeaseInterpreter` converts a
validated grant into stage-specific permits, while `LeaseRuntime` derives a bounded AssumeRole
session from each permit and rejects any session that could outlive the work deadline or grant.
None of those values claims that AWS work was revoked when the process lost authority.

Cross-authority commit is likewise explicit data rather than a phantom atomic transition.
`TargetCommitIntent` maintains a bounded registered-target projection with
prepare/read-back/complete/recover/compact actions; successor recovery resolves every global
nonterminal intent before permitting a new generation. `SmtpKeyRepair` is a pure exhaustive fold
over the finite authoritative key inventory and committed projection, while
`SmtpKeyRepairInterpreter` alone performs delete/wait/re-observe/create/compensate effects. The
production `AwsSesStack` composes these values with the typed retained authority, selected sink,
fenced encrypted backend, and fixed-role sessions. Sprint `4.47` is complete on that composition;
Sprint `5.17` derives and places one opaque nested retained-SES plan from the selected validation
set. The plan carries a typed target object-store precondition and exact transaction trace, while
its injected interpreter performs only the precondition and one registered atomic ensure. Sprint
`8.10` adds `Prodbox.Ses.Readiness`: captured AWS outputs remain at the interpreter boundary, while
a pure exhaustive fold classifies them as Ready, Pending, Failed, or Unobservable. The enclosing
interpreter alone owns bounded Pending polling; terminal states and timeout never become a typed
permit for SMTP materialization.

The lifecycle doctrine for destructive commands extends Plan/Apply with three
additional layers: a preflight `Precondition` check that refuses on residue
with structured remedies, a postflight tag sweep that fails the command if
any cluster-tagged resource survives, and a phase ADT that narrates the
sequential steps for `--dry-run` output and error reporting. The full
discipline lives in
[lifecycle_reconciliation_doctrine.md](./lifecycle_reconciliation_doctrine.md).

## Cross-References

- [Effect Interpreter Runtime Contract](./effect_interpreter.md)
- [Effectful DAG Architecture](./effectful_dag_architecture.md)
- [Unit Testing Policy](./unit_testing_policy.md)
- [Refactoring Patterns](./refactoring_patterns.md)
