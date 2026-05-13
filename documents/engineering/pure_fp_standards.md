# Pure Functional Programming Standards

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: README.md, AGENTS.md, CLAUDE.md, documents/engineering/README.md, documents/engineering/code_quality.md, documents/engineering/dependency_management.md, documents/engineering/effect_interpreter.md, documents/engineering/refactoring_patterns.md, documents/engineering/unit_testing_policy.md

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
[../../HASKELL_CLI_TOOL.md → At-Least-Once Event
Processing](../../HASKELL_CLI_TOOL.md) §1624–1739, exposed by
`src/Prodbox/Daemon/Events.hs` (introduced by Sprint 2.16 in
[../../DEVELOPMENT_PLAN/phase-2-gateway-dns.md](../../DEVELOPMENT_PLAN/phase-2-gateway-dns.md)).

The module provides `StoredEvent`, `recordEvent`, `markEventProcessed`,
`fetchUnprocessedEvents`, and the `EventHandler` newtype with the idempotency precondition
encoded in its haddock. Handlers must be idempotent: events may be delivered multiple times
(process crash before ack, network partition during ack, explicit replay). Idempotency
strategies include database constraints, check-then-act with a dedup key, or pure
projections of the event payload.

Pure planning logic must not duplicate the at-least-once pattern; consume the canonical
module instead.

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

## Cross-References

- [Effect Interpreter Runtime Contract](./effect_interpreter.md)
- [Effectful DAG Architecture](./effectful_dag_architecture.md)
- [Unit Testing Policy](./unit_testing_policy.md)
- [Refactoring Patterns](./refactoring_patterns.md)
