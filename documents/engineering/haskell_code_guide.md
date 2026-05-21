# Haskell Code Guide

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](../../README.md), [../../DEVELOPMENT_PLAN/phase-1-runtime-cli-aws-foundations.md](../../DEVELOPMENT_PLAN/phase-1-runtime-cli-aws-foundations.md), [README.md](./README.md), [code_quality.md](./code_quality.md), [dependency_management.md](./dependency_management.md), [pure_fp_standards.md](./pure_fp_standards.md)

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

- [Code Quality Doctrine](./code_quality.md) for the public `prodbox check-code` contract
- [Pure FP Standards](./pure_fp_standards.md) for purity, ADT, and effect-boundary doctrine
- [Dependency Management](./dependency_management.md) for host-tool and package ownership

## 2. Standards Model

This repository uses two kinds of Haskell standards.

### 2.1 Hard Gates

Hard gates are enforced mechanically. A change that fails one of these gates is incomplete.

Current hard gates:

- repository-owned workflow and hook policy scan through `prodbox check-code`
- Fourmolu formatting through the checked-in [`fourmolu.yaml`](../../fourmolu.yaml)
- HLint through the checked-in [`/.hlint.yaml`](../../.hlint.yaml)
- warning-clean Haskell compilation through
  `cabal build --builddir=.build all --ghc-options=-Werror`
- operator-binary sync to `.build/prodbox` after a successful quality gate

The workflow or hook policy scan is scoped to repo-owned surfaces and excludes generated or
retained runtime roots such as `.build/`, `dist-newstyle/`, `.prodbox-state/`, and `.data/`.

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
- `src/Prodbox/Retry.hs` owns `RetryPolicy` and pure backoff calculation.
- `src/Prodbox/Service.hs` owns `ServiceError`, capability classes, IO-backed MinIO / Redis /
  PostgreSQL service runners, and service-level retry helpers.
- `src/Prodbox/Naming.hs` owns DNS-1123-safe resource naming helpers.
- `src/Prodbox/StateMachine.hs` owns phantom-indexed transition surfaces for multi-state gateway,
  Pulumi, and chart workflows.

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
prodbox check-code
```

`src/Prodbox/CheckCode.hs` owns that command. The supported gate currently requires:

1. repository-owned workflow and hook policy scan
2. `fourmolu --mode check app src test`
3. `hlint app src test --hint=.hlint.yaml`
4. `cabal build --builddir=.build all --ghc-options=-Werror`
5. sync of the built operator binary to `.build/prodbox`

The policy-scan phase ignores generated or retained runtime roots such as `.build/`,
`dist-newstyle/`, `.prodbox-state/`, and `.data/`.

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
are not part of the supported development model, and `prodbox check-code` fails on repo-owned
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

## Capability Classes and Service Errors

Subsystem boundaries (object storage, cache, database, message queue) are abstracted
through capability classes. Each subsystem has its own error newtype wrapping a unified
`ServiceError`, and a conversion typeclass enables generic handling (retry logic, unified
reporting) without coupling.

### Unified service error type

```haskell
data ServiceError
    = SEConnectionFailed Text
    | SETimeout Text
    | SENotFound Text
    | SEPermissionDenied Text
    | SEConflict Text
    | SEInternalError Text
    deriving stock (Show, Eq)

newtype MinIOError = MinIOError { unMinIOError :: ServiceError }
    deriving stock (Show, Eq)

newtype RedisError = RedisError { unRedisError :: ServiceError }
    deriving stock (Show, Eq)

newtype PgError = PgError { unPgError :: ServiceError }
    deriving stock (Show, Eq)
```

### Conversion typeclass

```haskell
class AsServiceError e where
    toServiceError :: e -> ServiceError
    fromServiceError :: ServiceError -> e

instance AsServiceError MinIOError where
    toServiceError = unMinIOError
    fromServiceError = MinIOError
```

### Capability classes

```haskell
class (Monad m) => HasMinIO m where
    minioPutObject ::
        BucketName -> ObjectKey -> ByteString -> m (Either MinIOError ())
    minioGetObject ::
        BucketName -> ObjectKey -> m (Either MinIOError (Maybe ByteString))
    minioDeleteObject ::
        BucketName -> ObjectKey -> m (Either MinIOError ())

class (Monad m) => HasRedis m where
    redisGet :: RedisKey -> m (Either RedisError (Maybe ByteString))
    redisSet :: RedisKey -> ByteString -> TTLSeconds -> m (Either RedisError ())
    redisDelete :: RedisKey -> m (Either RedisError ())
```

### Generic retry across service errors

```haskell
retryServiceAction ::
    (AsServiceError e, MonadIO m) =>
    RetryPolicy ->
    m (Either e a) ->
    m (Either e a)
retryServiceAction policy action = go 1
  where
    go attempt
        | attempt > retryMaxAttempts policy = action
        | otherwise = do
            result <- action
            case result of
                Right a -> pure (Right a)
                Left e
                    | serviceErrorRetryable (toServiceError e) -> do
                        liftIO $ threadDelay (retryDelayMicros policy attempt)
                        go (attempt + 1)
                    | otherwise -> pure (Left e)
```

The `AsServiceError` constraint allows a single retry function to work with `MinIOError`,
`RedisError`, `PgError`, or any future subsystem error type.

**Forbidden patterns:**

- Stringly-typed errors (`Left "connection failed"`).
- Bare `SomeException` in return types.
- Subsystem-specific retry logic duplicated across call sites.
- Service errors that do not implement `AsServiceError`.

## Retry Policy as First-Class Values

Retry policies are explicit typed values, not hardcoded loops with magic numbers. The
policy definition is separate from error classification.

```haskell
data RetryPolicy = RetryPolicy
    { retryBaseDelayMicros :: Int
    , retryMaxDelayMicros :: Int
    , retryMaxAttempts :: Int
    }
    deriving stock (Show, Eq)

defaultRetryPolicy :: RetryPolicy
defaultRetryPolicy = RetryPolicy
    { retryBaseDelayMicros = 10_000
    , retryMaxDelayMicros = 1_000_000
    , retryMaxAttempts = 5
    }

retryDelayMicros :: RetryPolicy -> Int -> Int
retryDelayMicros policy attemptNumber =
    fromInteger $
        min (toInteger (retryMaxDelayMicros policy))
            (toInteger (retryBaseDelayMicros policy) *
             ((2 :: Integer) ^ max 0 (attemptNumber - 1)))

serviceErrorRetryable :: ServiceError -> Bool
serviceErrorRetryable = \case
    SEConnectionFailed _ -> True
    SETimeout _ -> True
    SEConflict _ -> True
    SEInternalError _ -> True
    SENotFound _ -> False
    SEPermissionDenied _ -> False
```

Default policy delay sequence: `[10000, 20000, 40000, 80000, 160000]` (10 ms → 160 ms).

**Forbidden patterns:**

- Hardcoded retry counts or delays in call sites.
- Retry logic without exponential backoff.
- Retrying non-retryable errors (not found, permission denied).
- Magic numbers for delay or attempt limits.

## Application Environment

Use an `Env` record threaded via `ReaderT Env IO`:

```haskell
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
- [Development Plan](../../DEVELOPMENT_PLAN/README.md)
