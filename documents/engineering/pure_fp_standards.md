# Pure Functional Programming Standards

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: README.md, AGENTS.md, CLAUDE.md, documents/engineering/README.md, documents/engineering/code_quality.md, documents/engineering/dependency_management.md, documents/engineering/effect_interpreter.md, documents/engineering/lifecycle_reconciliation_doctrine.md, documents/engineering/refactoring_patterns.md, documents/engineering/unit_testing_policy.md

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
extends this pattern across `prodbox rke2 delete`, `prodbox aws teardown`,
`prodbox pulumi <stack>-destroy`, and `prodbox nuke`, see
[lifecycle_reconciliation_doctrine.md](lifecycle_reconciliation_doctrine.md).

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

- A planner may decide that Harbor reconciliation is required.
- The boundary layer performs `docker`, `kubectl`, `helm`, `aws`, or `curl`.
- Output is translated back into typed success or failure for the caller.

## 6.3 At-Least-Once Event Processing

Daemons that consume events (peer commit log, future workload event surfaces, any future
worker) consume the canonical at-least-once pattern from
[At-Least-Once Event
Processing](../../documents/engineering/README.md)exposed by
`src/Prodbox/Daemon/Events.hs` (introduced by Sprint 2.16 in
[../../DEVELOPMENT_PLAN/phase-2-gateway-dns.md](../../DEVELOPMENT_PLAN/phase-2-gateway-dns.md)).

The module provides `StoredEvent`, `recordEvent`, `markEventProcessed`,
`fetchUnprocessedEvents`, and the `EventHandler` newtype with the idempotency precondition
encoded in its haddock. Handlers must be idempotent: events may be delivered multiple times
(process crash before ack, network partition during ack, explicit replay). Idempotency
strategies include database constraints, check-then-act with a dedup key, or pure
projections of the event payload.

Pure planning logic must not duplicate the at-least-once pattern; consume the canonical
module instead. The gateway peer-gossip commit log intentionally remains the in-memory
anti-entropy variant documented in
[Distributed Gateway Architecture](./distributed_gateway_architecture.md#721-at-least-once-correspondence):
it shares the idempotency and ordering discipline but does not need durable `processed_at`
tracking because peers merge complete signed batches by event hash rather than acknowledging a
work queue.

## 7. Testing Implications

Pure-functional structure is not stylistic only; it determines how code is tested.

- Pure helpers are tested directly in `test/unit/Main.hs`.
- Built-frontend command behavior is tested in `test/integration/Main.hs` through
  `test/integration/CliSuite.hs` and `test/integration/EnvSuite.hs`.
- Real infrastructure-backed behavior is tested through named `prodbox test integration ...`
  validations.
- Mocks belong at subprocess or interpreter boundaries, not inside pure planners.

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

State machines with more than two states must use GADTs with phantom type parameters to
encode valid transitions at the type level. Invalid transitions become compile errors, not
runtime errors.

The prescribed shape:

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
- Status fields as `Text` or `String` with string comparisons.
- State machines with more than two states that do not use GADT indexing.
- Existential wrappers without singleton witnesses (losing type information).

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
