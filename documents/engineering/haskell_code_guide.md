# Haskell Code Guide

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](../../README.md), [../../DEVELOPMENT_PLAN/phase-1-runtime-cli-aws-foundations.md](../../DEVELOPMENT_PLAN/phase-1-runtime-cli-aws-foundations.md), [README.md](./README.md), [code_quality.md](./code_quality.md), [dependency_management.md](./dependency_management.md), [pure_fp_standards.md](./pure_fp_standards.md)
**Generated sections**: none

> **Purpose**: Define the repository's Haskell coding standards, the hard mechanical gates that
> enforce them, and the review guidance that remains human-judged.

## 1. Scope

This guide applies to the supported Haskell worktree:

- `app/`
- `src/Prodbox/`
- `test/`
- `prodbox.cabal`
- `cabal.project`
- repository-owned Dockerfiles under `docker/` where the Haskell build gate is invoked

This document complements, rather than replaces:

- [Code Quality Doctrine](./code_quality.md) for the public `prodbox dev check` contract
- [Pure FP Standards](./pure_fp_standards.md) for purity, ADT, and effect-boundary doctrine
- [Dependency Management](./dependency_management.md) for host-tool and package ownership

## 2. Standards Model

This repository uses two kinds of Haskell standards.

### 2.1 Hard Gates

Hard gates are enforced mechanically. A change that fails one of these gates is incomplete.

Current hard gates:

- repository-owned workflow and hook policy scan through `prodbox dev check`
- Fourmolu formatting through the checked-in [`fourmolu.yaml`](../../fourmolu.yaml)
- HLint through the checked-in [`/.hlint.yaml`](../../.hlint.yaml)
- warning-clean Haskell compilation through
  `cabal build --builddir=.build all --ghc-options=-Werror`
- operator-binary sync to `.build/prodbox` after a successful quality gate

The workflow or hook policy scan is scoped to repo-owned surfaces and excludes generated or
retained runtime roots such as `.build/`, `dist-newstyle/`, and `.data/`.

### 2.2 Review Guidance

Review guidance is still part of the coding standard, but it is not mechanically proven by the
formatter or compiler switch.

Current review guidance includes:

- prefer explicit ADTs and pattern matches over stringly control flow
- keep side effects at CLI, interpreter, or subprocess boundaries
- isolate pure helpers around parsing, rendering, and planning logic
- keep modules cohesive around one owned runtime or domain surface
- add brief comments only when control flow is genuinely non-obvious

The build must not pretend to enforce guidance that it cannot actually prove.

### 2.3 Shared Runtime Foundations

The current supported worktree has started converging on a small shared foundation layer:

- `src/Prodbox/Subprocess.hs` owns structured subprocess construction and the `runStreaming` /
  `capture` interpreter boundary, backed by `typed-process` inside that boundary only.
- `src/Prodbox/Gateway/Logging.hs` owns structured daemon JSON logging through `co-log`; daemon
  log sites use typed `field` values and threshold-aware emission instead of direct terminal
  writes.
- `src/Prodbox/App.hs` owns the one-shot `Env` / `App` foundation backed by
  `ReaderT Env IO`.
- `src/Prodbox/Error.hs` owns `AppError` plus the `Recoverable` / `Fatal` split.
- `src/Prodbox/CLI/Output.hs` owns user-facing error rendering, stdout/stderr writer helpers,
  and typed `OutputOptions` rendering at the CLI boundary.
- `src/Prodbox/Retry.hs` owns `RetryPolicy` and pure backoff calculation (the `AppError`-keyed
  retrier).
- `src/Prodbox/Service.hs` owns `ServiceError`, the argv-shaped capability classes, the IO-backed
  MinIO / Redis / PostgreSQL service runners, the constructor-owned transient-failure classifier,
  and the service-level retry helper.
- `src/Prodbox/Naming.hs` owns DNS-1123-safe resource naming helpers.
- `src/Prodbox/Lifecycle/ReadinessObservation.hs` owns flat exhaustive projections of externally
  authoritative readiness. GADT-indexed transitions remain reserved for real in-process authority;
  the former unused `Prodbox.StateMachine` experiment is deleted.

These modules are closed doctrine-adoption surfaces. New code should prefer them over ad-hoc
reimplementations.

## 3. Repository-Owned Inputs

The current repository-owned Haskell style and lint inputs are:

- [`fourmolu.yaml`](../../fourmolu.yaml) for formatting
- [`.hlint.yaml`](../../.hlint.yaml) for lint policy
- [`.editorconfig`](../../.editorconfig) for editor ergonomics only

Important distinction:

- `fourmolu.yaml` is a hard-gate input
- `.hlint.yaml` is a hard-gate input
- `.editorconfig` is not a build-acceptance input

## 4. Canonical Commands

The authoritative mechanical Haskell quality gate is:

```bash
prodbox dev check
```

`src/Prodbox/CheckCode.hs` owns that command. The supported gate currently requires:

1. repository-owned workflow and hook policy scan
2. `fourmolu --mode check app src test`
3. `hlint app src test --hint=.hlint.yaml`
4. `cabal build --builddir=.build all --ghc-options=-Werror`
5. sync of the built operator binary to `.build/prodbox`

The policy-scan phase ignores generated or retained runtime roots such as `.build/`,
`dist-newstyle/`, and `.data/`.

The broader validation surfaces remain separate:

```bash
prodbox test unit
prodbox test integration cli
prodbox test integration env
prodbox test all
```

Those suites validate runtime behavior and owned proof flows. They do not replace `check-code` as
the canonical formatter/linter/warning-clean gate.

## 5. Tooling Policy

The repository uses local CLI entrypoints only. CI workflows, `.github/` automation, and git hooks
are not part of the supported development model, and `prodbox dev check` fails on repo-owned
workflow or hook surfaces that would violate that policy.

See [Code Quality Doctrine](./code_quality.md#2a-development-tooling-policy) for the public policy
statement.

## Project Structure

Prefer a library-first project layout:

```text
my-tool/
  app/Main.hs
  src/MyTool/App.hs
  src/MyTool/CLI.hs
  src/MyTool/Commands.hs
  src/MyTool/Config.hs
  src/MyTool/Output.hs
  src/MyTool/Error.hs
  test/
```

`Main.hs` should be small:

```haskell
module Main where

import MyTool.App qualified as App

main :: IO ()
main = App.main
```

Most logic should live in `src/`, not `app/`, so it can be imported by tests and reused by other programs.

The prescribed module layout for a CLI app:

```text
MyTool.CLI.Spec       -- command metadata
MyTool.CLI.Parser     -- optparse-applicative backend
MyTool.CLI.Docs       -- Markdown/manpage generation
MyTool.CLI.Tree       -- command tree rendering
MyTool.CLI.Json       -- JSON command schema
MyTool.Commands       -- command ADTs
MyTool.Subprocess     -- typed subprocess values + interpreter
MyTool.App            -- application runtime
```

## Subprocesses as Typed Values

Subprocess invocations are pure values, not IO calls scattered through command
runners. Build them in pure code, render them in pure code, and hand them to an
interpreter only at the boundary.

The prescribed shape:

```haskell
data Subprocess = Subprocess
  { subprocessPath             :: FilePath
  , subprocessArguments        :: [Text]
  , subprocessEnvironment      :: Maybe [(Text, Text)]
  , subprocessWorkingDirectory :: Maybe FilePath
  }
  deriving stock (Eq, Show)

renderSubprocess :: Subprocess -> Text  -- pure; for logs, --dry-run, golden tests
```

The interpreter API:

```haskell
runStreaming :: Subprocess -> IO (Either AppError ExitCode)
capture      :: Subprocess -> IO (Either AppError ProcessOutput)
```

Why this matters:

- Subprocess sequences become deterministic golden-test targets.
- `--dry-run` is trivial: render and print the planned subprocesses, exit 0.
- The type system rules out "forgot to set cwd" or "leaked stale env" bugs at
  the call site.
- Subprocesses compose as plain data — a `[Subprocess]` is a first-class plan
  (see [Plan / Apply](./pure_fp_standards.md#plan--apply)).

**Forbidden patterns:**

- Calling `callProcess`, `readCreateProcess`, `System.Process` constructors, or
  `typed-process` smart constructors directly from a command runner. The two
  interpreter functions above are the only IO boundary for subprocess
  execution.
- Resolving paths, expanding env vars, or branching on the host inside the
  interpreter. The builder is total; the interpreter executes what it's given.
- Returning subprocess output through `IORef`, `MVar`, or other shared mutable
  state instead of the typed `ProcessOutput` record.
- Reading configuration from environment variables. `lookupEnv`, `getEnv`, and
  `getEnvironment` from `System.Environment` are linted out of supported config-
  loading paths (host `Settings.hs`, daemon `Gateway/Settings.hs`, workload
  entrypoint). Every runtime configuration value lives in the Dhall file at
  `--config`. The k8s Pod environment may still carry runtime metadata (Pod
  name, namespace) that the binary does not read; the lint rule is scoped to
  the config-loading paths. See
  [config_doctrine.md](./config_doctrine.md).

### Subprocess environments must be PATH-preserving

`Subprocess.subprocessEnvironment` is `Maybe [(Text, Text)]`, and the interpreter applies it
with `typed-process`'s `setEnv`, which **replaces** the child environment wholesale — it does
not merge with the parent's. So a `Just []` (or any list that simply omits `PATH`/`HOME`) hands
the child process an environment with *no* `PATH`: the vendor CLI cannot resolve its own helper
binaries, find a credentials file under `$HOME`, or locate anything off the search path.

Any subprocess that needs auth or path-sensitive state — every `aws` invocation in particular —
must therefore build its environment by *overlaying* the desired keys onto the inherited parent
environment, never by handing the child a from-scratch list. This is the job of one canonical
`awsCliSubprocessEnvironment :: Credentials -> IO [(String, String)]` helper: read the parent
environment with `getEnvironment`, strip ambient AWS auth keys, then overlay the repo-root
credentials. There must be exactly one such builder; the divergence Sprint 1.30 closes is that
`Dns.hs` currently overlays onto an **empty** base (`overlayAwsCredentials []`), dropping `PATH`,
while `AwsEksSubzoneStack.hs` correctly overlays onto `getEnvironment`. Both must route through
the single PATH-preserving builder.

**Forbidden patterns:**

- Constructing an `aws`/`kubectl`/`redis-cli` subprocess environment from an empty or
  literal-only list that omits `PATH` and `HOME`.
- A second, parallel "AWS CLI environment" builder. There is one
  `awsCliSubprocessEnvironment`; everything else calls it.

## Smart Constructors for Paired Resources

When a system creates related resources that must stay consistent (e.g., a Kubernetes
PersistentVolume and its PersistentVolumeClaim, a database user and its grants, a queue
and its dead-letter queue), derive both resources from a single source of truth via a
smart constructor. The smart constructor guarantees consistency by construction — there
is no code path that can create one resource without creating its pair.

```haskell
-- | Paired PV + PVC that are guaranteed to bind
data StorageBinding = StorageBinding
    { bindingPV :: PlannedPV
    , bindingPVC :: ExpectedPVC
    }
    deriving stock (Show, Eq)

-- | Smart constructor: both resources derived from same inputs
mkStorageBinding ::
    Text -> Text -> Text -> Text -> Int -> Text -> Text -> [Text] ->
    StorageBinding
mkStorageBinding namespace release workload claimTemplate ordinal
                 storageClass capacity accessModes =
    let
        baseName = T.intercalate "-"
            [claimTemplate, workload, T.pack (show ordinal)]
        pvcName = boundedResourceName namespace release baseName
        pvName = "pv-" <> hashSuffix (namespace <> "/" <> pvcName)
    in
        StorageBinding
            { bindingPV = PlannedPV { pvName = pvName, ..., pvClaimRef = PVClaimRef pvcName namespace }
            , bindingPVC = ExpectedPVC { pvcName = pvcName, pvcNamespace = namespace, ... }
            }
```

### Naming helpers for platform constraints

When resources have naming constraints (DNS-1123 labels, maximum lengths, character
restrictions), centralize enforcement in helper functions:

```haskell
-- | Enforce DNS-1123 label constraints (max 63 chars)
boundedResourceName :: Text -> Text -> Text -> Text
boundedResourceName namespace release base =
    let full = T.intercalate "-" [release, base]
        maxLen = 63
    in
        if T.length full <= maxLen
            then sanitizeResourceName full
            else
                let suffix = hashSuffix full
                    truncated = T.take (maxLen - 1 - T.length suffix) full
                in sanitizeResourceName (truncated <> "-" <> suffix)

sanitizeResourceName :: Text -> Text
sanitizeResourceName = T.map sanitizeChar . T.toLower
  where
    sanitizeChar c
        | c >= 'a' && c <= 'z' = c
        | c >= '0' && c <= '9' = c
        | c == '-' = c
        | otherwise = '-'

hashSuffix :: Text -> Text
hashSuffix input = T.take 8 . T.pack . show $
    (hash (BS8.pack (T.unpack input)) :: Digest SHA256)
```

**Forbidden patterns:**

- Constructing paired resources independently in separate code paths.
- Hardcoding resource names without platform constraint enforcement.
- Manual name synchronization between related resources.
- Length truncation without hash suffixes (collisions).

## Error Handling

Define domain-level errors as ADTs:

```haskell
data AppError
  = ConfigMissing FilePath
  | InvalidInput Text
  | UserNotFound Text
  | NetworkFailed Text
  deriving stock (Show, Eq)
```

Render errors only at the CLI boundary:

```haskell
renderError :: AppError -> Text
renderError = \case
  ConfigMissing path -> "config file not found: " <> toText path
  InvalidInput msg   -> "invalid input: " <> msg
  UserNotFound name  -> "user not found: " <> name
  NetworkFailed msg  -> "network error: " <> msg
```

Keep the core logic free of:

- `putStrLn`
- `print`
- `exitFailure`
- direct terminal formatting

Daemons require an additional axis: errors carry an `ErrorKind` of `Recoverable`
or `Fatal`. Worker loops handle `Recoverable` by logging at warn level and
retrying with bounded backoff; `Fatal` propagates to the top-level supervisor,
which begins drain. See
[distributed_gateway_architecture.md → Daemon Lifecycle → Error handling: recoverable vs fatal](./distributed_gateway_architecture.md#daemon-lifecycle).

## Shared HTTP Client Manager (Sprint 1.64)

`Prodbox.Http.Client` owns **one** process-wide TLS `Manager` (`sharedTlsManager`), constructed
exactly once through the `unsafePerformIO` + `{-# NOINLINE #-}` idiom. `http-client` `Manager`s are
designed for concurrent reuse and pool connections per host, so a single shared manager is both
correct and the point: counterexample `LCPC-2026-07-11` traced a gateway hot-path CPU driver to the
old per-call `newManager` construction (a fresh TLS context and connection pool on every request).
Never construct a `Manager` per call. This singleton lives only in `Prodbox.Http.Client`, outside
every daemon-runtime module (where module-level mutable state is forbidden), and the manager is
immutable after construction. The cached renewable Vault Kubernetes-auth session
(`Prodbox.Vault.Session`) rides on the same shared manager and is documented in
[vault_doctrine.md § 12.1](./vault_doctrine.md).

### Native SigV4 object-store client (Sprint 1.66)

`Prodbox.Aws.SigV4` implements the pure, byte-exact AWS Signature Version 4 algorithm (canonical
request, string-to-sign, HMAC signing-key chain, and authorization header), unit-tested against
published AWS vectors. `Prodbox.Minio.ObjectStoreNative` builds on it and the shared TLS `Manager`
to perform every Model-B object-store operation (get/put/conditional-put/list/head/create/delete)
as an in-memory, SigV4-signed S3 request — **no `aws` CLI subprocess and no per-operation temp-file
bodies** (the third gateway hot-path CPU driver from counterexample `LCPC-2026-07-11`). Bodies are
held in memory as strict `ByteString`s; the `x-amz-content-sha256` header binds the exact body, and
ETag conditional semantics (`If-Match`/`If-None-Match`) preserve the compare-and-swap outcome
taxonomy (`ConditionalPutConflict` on a `412`, positive absence on a `404`).

The native and subprocess clients are drop-in interchangeable through the `ObjectStoreBackend`
selector in `Prodbox.Minio.ObjectStore` (`objectStoreBackend`); the subprocess path remains the
default and config-selectable rollback until the native client's live-MinIO parity is proven, then
it is deleted through the legacy ledger. The signing algebra is pure and testable; the live parity is
a Standard-O live-proof axis.

## Capability Classes and Service Errors

Subsystem boundaries (object storage, cache, database) are abstracted through *argv-shaped*
capability classes. The supported services in this worktree are driven by invoking a vendor
CLI (`aws`, `redis-cli`, `kubectl`) as a typed [`Subprocess`](#subprocesses-as-typed-values),
not by linking a native protocol client. Each capability class therefore exposes a single
runner that takes the argument vector and returns the captured `ProcessOutput`, and each
subsystem has its own error newtype wrapping a unified `ServiceError`. A conversion typeclass
enables generic handling (retry, unified reporting) without coupling.

`src/Prodbox/Service.hs` is the closed home of this surface.

### Argv-shaped capability classes

The runner takes the CLI argument vector and yields the typed `ProcessOutput`:

```haskell
class (Monad m) => HasMinIO m where
    runMinIO :: [String] -> m (Either MinIOError ProcessOutput)
    runMinIOWithEnv ::
        Maybe [(String, String)] -> [String] -> m (Either MinIOError ProcessOutput)
    runMinIOWithEnv _ = runMinIO

class (Monad m) => HasRedis m where
    runRedis :: [String] -> m (Either RedisError ProcessOutput)

class (Monad m) => HasPg m where
    runPg :: [String] -> m (Either PgError ProcessOutput)
```

The `IO` instances bind each class to its vendor CLI: `runMinIO` to `aws` (the S3-compatible
MinIO path), `runPg` to `kubectl` (Patroni/Percona access through `kubectl exec`), and
`runRedis` to `redis-cli`.

> **`HasRedis` is vestigial.** It has *zero* `src/` callers in the current worktree — no
> supported code path drives Redis through this class. It is retained as the shape a future
> Redis-backed surface would adopt, not as live doctrine. A reviewer touching `Service.hs`
> should not treat `HasRedis`/`runRedis`/`RedisError` as load-bearing; Sprint 1.30 may delete
> the dead exports outright if no caller has appeared.

### Unified service error type and conversion typeclass

Every subsystem error is a newtype over one `ServiceError`, and `AsServiceError` lets a single
retry helper work across `MinIOError`, `RedisError`, `PgError`, or any future subsystem error.

```haskell
newtype MinIOError = MinIOError { unMinIOError :: ServiceError }
    deriving stock (Show, Eq)

newtype RedisError = RedisError { unRedisError :: ServiceError }
    deriving stock (Show, Eq)

newtype PgError = PgError { unPgError :: ServiceError }
    deriving stock (Show, Eq)

class AsServiceError e where
    toServiceError :: e -> ServiceError
    fromServiceError :: ServiceError -> e
```

### Target shape: `ServiceError` classified by constructor (Sprint 1.30)

The retry helper must be able to ask "is this error retryable?" *structurally* — never by
trusting a `Bool` that some call site set by hand. The current `Service.hs` shape is a known
gap: it carries a `serviceErrorRetryable :: Bool` field and the single subprocess wrapper
hardcodes it to `True`, so retryability is asserted at the constructor, not derived from the
failure. Sprint 1.30 reshapes `ServiceError` into a *classified sum* whose retryability is a
total function of its constructor, classified once at the single subprocess boundary:

```haskell
-- Sprint 1.30 target shape.
data ServiceError
    = SEConnectionFailed Text
    | SETimeout Text
    | SENotFound Text
    | SEPermissionDenied Text
    | SEConflict Text
    | SEInternalError Text
    deriving stock (Show, Eq)

serviceErrorRetryable :: ServiceError -> Bool
serviceErrorRetryable = \case
    SEConnectionFailed _ -> True
    SETimeout _ -> True
    SEConflict _ -> True
    SEInternalError _ -> True
    SENotFound _ -> False
    SEPermissionDenied _ -> False
```

Classification happens **once**, where the subprocess result is observed (exit code, stderr
shape), and is the only place that decides which constructor a failure becomes. Downstream
code reads the classification; it never re-decides retryability.

### Shared transient subprocess-failure classifier (Sprint 1.57)

A subprocess that started and returned a non-zero exit has a `ProcessOutput`, not a
`ServiceError`. Retry decisions over that rendered output use the shared constructor-owned base in
`Prodbox.Service`:

```haskell
data TransientFailureClass
    = TransientNameResolutionFailure
    | TransientConnectionFailure
    | TransientHttpFailure
    | TransientTimeoutFailure
    deriving (Bounded, Enum, Eq, Show)

isRetryableTransientFailure :: [String] -> String -> Bool
```

Each `TransientFailureClass` constructor owns its common fragments. The first argument to
`isRetryableTransientFailure` contains only operation-specific extensions, such as AWS token
propagation errors or a Helm fetch failure; the helper case-normalizes both the extensions and the
observed detail. A caller does not copy the shared name-resolution, connection, transient-HTTP, or
timeout fragments into its own module.

`checkInlineRetrySubstringLists` in `Prodbox.CheckCode` mechanically rejects a new top-level
`isRetryable*` definition that performs its own `any`/`isInfixOf` substring-table scan without
delegating to `isRetryableTransientFailure`. During adoption, its allowlist was limited to exact
path-and-function pairs for the Route 53, Helm, Harbor, and EKS classifiers. Sprint `4.46` removed
all three RKE2 exceptions when those callers migrated; Sprint `7.32` removed the final EKS
exception. No legacy classifier allowance remains.

### Generic retry across service errors

```haskell
retryServiceAction ::
    (AsServiceError e) =>
    RetryPolicy ->
    IO (Either e a) ->
    IO (Either e a)
retryServiceAction policy action = go 0
  where
    go attemptIndex = do
        result <- action
        case result of
            Left e
                | serviceErrorRetryable (toServiceError e)
                    && attemptIndex + 1 < retryPolicyMaxAttempts policy -> do
                    threadDelay (retryDelayMicros policy attemptIndex)
                    go (attemptIndex + 1)
            _ -> pure result
```

The `AsServiceError` constraint allows this single helper to work with any subsystem error
type. It retries **only** when the classified error says it is retryable; a non-retryable
constructor short-circuits immediately.

**Forbidden patterns:**

- Stringly-typed errors (`Left "connection failed"`).
- Bare `SomeException` in return types.
- Hand-building a `ServiceError` with a literal `retryable` `Bool` at a call site — retryability
  is a function of the classified constructor, decided once at the subprocess boundary, never
  asserted by the caller.
- Retrying a non-retryable error (not-found, permission-denied) by classifying it as retryable
  to "get the loop to run".
- Defining a new top-level `isRetryable*` substring table instead of delegating common transient
  groups to `isRetryableTransientFailure` and supplying only operation-specific extensions.
- Subsystem-specific retry logic duplicated across call sites.
- Service errors that do not implement `AsServiceError`.

## Retry Policy as First-Class Values

Retry policies are explicit typed values, not hardcoded loops with magic numbers. The
policy definition (in `src/Prodbox/Retry.hs`) is separate from error classification, and the
multiplier is an explicit field rather than a literal `2` baked into the delay function:

```haskell
data RetryPolicy = RetryPolicy
    { retryPolicyMaxAttempts :: Int
    , retryPolicyBaseDelayMicros :: Int
    , retryPolicyMultiplier :: Int
    , retryPolicyMaxDelayMicros :: Int
    }
    deriving (Eq, Show)

defaultRetryPolicy :: RetryPolicy
defaultRetryPolicy = RetryPolicy
    { retryPolicyMaxAttempts = 5
    , retryPolicyBaseDelayMicros = 500000
    , retryPolicyMultiplier = 2
    , retryPolicyMaxDelayMicros = 30000000
    }

retryDelayMicros :: RetryPolicy -> Int -> Int
retryDelayMicros policy attemptIndex =
    min
        (retryPolicyMaxDelayMicros policy)
        ( retryPolicyBaseDelayMicros policy
            * retryPolicyMultiplier policy ^ max 0 attemptIndex
        )
```

`retryDelayMicros` is the shared pure backoff calculation. With the default policy it yields
`[500000, 1000000, 2000000, 4000000, 8000000]` microseconds (0.5 s → 8 s, capped at 30 s).

### Two distinct retry shapes — keep them separate

There are two callers of `retryDelayMicros`, and they answer different questions. Sprint 1.30
keeps these split rather than collapsing them into one loop:

- **The retrier** (`retryAppError` in `Retry.hs`, `retryServiceAction` in `Service.hs`) re-runs
  a *failing* action while its error is classified retryable: `retryAppError` retries on an
  `AppError` whose `errorKind` is `Recoverable`; `retryServiceAction` retries on a `ServiceError`
  whose constructor is retryable. Both stop as soon as the action succeeds or the error is
  non-retryable, and are bounded by `retryPolicyMaxAttempts`.
- **The readiness poller** waits for a *not-yet-true* external condition to become true (a Pod
  reporting Ready, a DNS record propagating, a stack converging). It loops on a *successful*
  observation that reports "not ready yet", which is the opposite control-flow shape from
  retrying a *failed* action. It must not be expressed as `retryServiceAction`/`retryAppError`,
  because a "still pending" reading is not an error and must not be classified as one.

Both may share the `RetryPolicy` backoff schedule, but the poller is its own function. Folding
"poll until ready" into the error retrier conflates a pending observation with a failure.

Sprint `1.59`'s three-valued observation remains useful historical groundwork, but its
caller-injected `IO` target is superseded. Target code carries a pure
`CapabilityRequirement`, resolves one opaque `CapabilityRef kind`, and passes that same reference
to observation, admission, and the compatible `CapabilityProgram kind result` under one absolute
deadline. `Pending` and `Unobservable` remain distinct gate-closed values. An arbitrary action,
separately supplied endpoint, nested fresh timeout, or component label cannot authorize execution;
see [Lifecycle Control-Plane Architecture](./lifecycle_control_plane_architecture.md).

**Forbidden patterns:**

- Hardcoded retry counts or delays in call sites.
- Retry logic without exponential backoff (the `retryPolicyMultiplier` field).
- Retrying non-retryable errors (not found, permission denied).
- Magic numbers for delay or attempt limits.
- Driving a readiness poll through the error retrier, or modelling a "still pending" reading as
  a retryable error.

## Runtime Memory And RTS Policy

The authored Kubernetes limit is not a Haskell heap plan. The landed
`Prodbox.Capacity.RuntimeMemory` module constructs an opaque `RuntimeMemoryPlan` whose inner
inequality bounds retained Haskell state, in-heap decode/transport scratch, and other heap reserve
under `heap_cap`; its outer inequality bounds that heap cap plus native/non-heap, admitted
child-process, kernel/cgroup, and safety reserves under the container limit. `PositiveBytes`,
`ChildProcessBudget`, and the plan hide their constructors, while `RuntimeMemoryError` preserves the
exact failed term or inequality. The authoritative algebra is in
[Resource Scaling Doctrine §2D](./resource_scaling_doctrine.md#2d-runtime-memory-decomposition-and-observation).

`Prodbox.Capacity.Config.runtimeMemoryPlanForProfile` derives the cgroup authority from the matching
workload profile's `ResourceEnvelope.limit.memory_mib`; runtime config cannot author a second
container limit. The validator rejects unbounded or malformed child schedules. Capacity one uses
the maximum serialized peak, while greater concurrency requires one peak per simultaneous permit
and sums them.

`RuntimeMemory.runtimeMemoryRtsArguments` derives `+RTS -M<exact-bytes> -RTS` solely from the
validated heap cap. `ChartPlatform.valuesForGateway` emits those arguments and the gateway chart
appends them to the container argv, before application code runs. Only the `prodbox` executable
stanza enables `-rtsopts`; no `-with-rtsopts`, `GHCRTS`, Docker setting, or Helm default owns a heap
value. The same union image continues to serve gateway, API, and WebSocket roles without imposing a
single global heap cap on every role.

The plan projects a typed high-water threshold, but external behavior stays outside the
constructor proof. Sprint `2.31` landed gateway-specific bounded state/transport and capacity-one
child-permit enforcement through `Prodbox.Gateway.Bounds`, `Prodbox.Gateway.ChildSchedule`, and the
daemon interpreters. Sprint `5.16` owns restart/OOM/high-water observation and the non-blocking live
soak. Profiling calibrates authored values; it never replaces either nested validation or external
observation.

## Application Environment

Use an `Env` record threaded via `ReaderT Env IO`:

```haskell
-- Example: application environment shape
data Env = Env
  { envConfig :: Config
  , envLog    :: LogFn
  }

newtype App a = App
  { unApp :: ReaderT Env IO a
  }
  deriving newtype
    ( Functor
    , Applicative
    , Monad
    , MonadIO
    , MonadReader Env
    )
```

This keeps configuration, logging, and dependencies organized.

Daemons need a richer `Env` (resource handles, structured logger, metrics
registry, shutdown signal, hot-reloadable live config). See
[distributed_gateway_architecture.md → Daemon Lifecycle → The Env record grows](./distributed_gateway_architecture.md#daemon-lifecycle).

## Cross-References

- [Code Quality Doctrine](./code_quality.md)
- [Pure FP Standards](./pure_fp_standards.md)
- [Dependency Management](./dependency_management.md)
- [Resource Scaling Doctrine](./resource_scaling_doctrine.md)
- [Development Plan](../../DEVELOPMENT_PLAN/README.md)
