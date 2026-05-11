# Haskell CLI Tool Design Notes

## Overview

The best practice for writing CLI tools in Haskell is to keep the command-line layer thin, make the core logic testable, and treat the command topology as structured data that can be used for parsing, help, documentation, completions, and introspection.

The standardized stack for CLI tooling is:

```haskell
optparse-applicative   -- CLI parsing, help, subcommands, completions
text                   -- textual data
bytestring             -- binary and IO-heavy data
aeson                  -- JSON
dhall                  -- strongly-typed daemon configuration
prettyprinter          -- structured human-readable output
prettyprinter-ansi-terminal
ansi-terminal          -- terminal color support
path
path-io                -- safer filesystem paths
typed-process          -- subprocesses
safe-exceptions        -- exception handling

tasty                  -- test runner
tasty-hunit            -- unit assertions
tasty-quickcheck       -- property tests
tasty-golden           -- golden tests

temporary              -- temporary files/directories
pulumi                 -- infrastructure orchestration for cloud tests
```

Use Cabal as the standard build tool.

The standard Cabal test interface is:

```text
exitcode-stdio-1.0
```

All projects standardize on this stack.

### Toolchain pinning

The exact GHC and Cabal versions every project under this doctrine builds with:

```text
GHC 9.14.1
Cabal 3.16.1.0
```

These are not floors or recommendations. The `.cabal` file declares
`tested-with: ghc ==9.14.1`. A `cabal.project` (or equivalent) pins
`with-compiler: ghc-9.14.1`. CI uses the same versions. The pinned formatter-tools
GHC under `.build/<project>-style-tools/` is a separate isolated install and is
managed by the lint stack; the project's main compiler is the version named here.

---

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

---

## Command Topology

Represent commands as ordinary Haskell data types:

```haskell
data Command
  = Users UsersCommand
  | Projects ProjectsCommand
  | Config ConfigCommand
  deriving stock (Show, Eq)

data UsersCommand
  = UsersList UsersListOptions
  | UsersCreate UsersCreateOptions
  | UsersDelete UsersDeleteOptions
  deriving stock (Show, Eq)
```

This gives you a typed model of the CLI surface.

Define a separate `CommandSpec` and generate the parser from it. The parser is never the source of truth.

---

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

import Data.Kind (Type)
import Data.Text (Text)
import Data.UUID (UUID)

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
-- | Existential wrapper for runtime-loaded orders
data SomeOrder where
    SomeOrder ::
        SOrderStatus s ->
        OrderHandle s ->
        SomeOrder

-- | Load from database, recovering type information
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

---

## Progressive Introspection

A good CLI should be introspectable at every level:

```bash
tool --help
tool users --help
tool users create --help
tool projects archive --help
```

Expose explicit introspection commands:

```bash
tool commands
tool commands --tree
tool commands --json
tool help users
tool help users create
```

Example tree output:

```text
tool
├── users
│   ├── list
│   ├── create
│   └── delete
├── projects
│   ├── list
│   └── archive
└── config
    ├── get
    └── set
```

---

## Automatically Generated Documentation

`optparse-applicative` can automatically generate:

- `--help` output
- usage text
- subcommand help
- shell completion support

However, for durable external documentation such as Markdown, manpages, HTML, or JSON command schemas, define a first-class command specification.

Example:

```haskell
data CommandSpec = CommandSpec
  { name        :: Text
  , summary     :: Text
  , description :: Text
  , children    :: [CommandSpec]
  , options     :: [OptionSpec]
  , examples    :: [Example]
  }

data OptionSpec = OptionSpec
  { longName    :: Text
  , shortName   :: Maybe Char
  , metavar     :: Maybe Text
  , description :: Text
  , required    :: Bool
  }

data Example = Example
  { exampleCommand     :: Text
  , exampleDescription :: Text
  }
```

Use the specification as the source of truth:

```text
CommandSpec
  -> optparse-applicative Parser
  -> Markdown documentation
  -> manpage
  -> JSON schema
  -> shell completion metadata
  -> command tree output
```

This avoids duplicating command descriptions across code, README files, and generated help text.

See the **Generated Artifacts** section below for the full discipline (markers, paired check/write commands, drift enforcement).

---

## Generated Artifacts

The earlier section sketched what a `CommandSpec` *can* be used to emit. This section
defines the full discipline: how generation is delimited, enforced, and regenerated for
every text artifact a CLI tool derives from typed Haskell data.

### Pattern

Any text artifact derived from typed Haskell data follows the same shape:

```text
typed Haskell value
  -> render function (pure, deterministic, String/Text)
  -> embedded between sentinel markers in a checked-in file
     OR written wholesale to a tracked-generated path
```

This applies to CLI help, command reference docs, route inventories, Helm chart
sections, cross-language type bridges, JSON command schemas, and anything else where
the in-repo artifact must reflect the code.

### The generated-section registry

A single Haskell value of type `[GeneratedSectionRule]` is the source of truth. Both
the validator and the writer consume it:

```haskell
data GeneratedSectionRule = GeneratedSectionRule
  { artifactPath :: FilePath
  , startMarker  :: Text
  , endMarker    :: Text
  , expected     :: Text   -- the renderer's current output
  }
```

Each rule pairs a renderer's output with the file path and marker pair it must appear
between. Adding a new generated region means adding a new entry to this list — nothing
else, because every consumer of the discipline reads from this single registry.

### Marker conventions

Markers are sentinel comments in the host syntax of the target file:

| File type | Start marker | End marker |
|---|---|---|
| Markdown | `<!-- <project>:<key>:start -->` | `<!-- <project>:<key>:end -->` |
| Helm / Go templates | `{{/* <project>:<key>:start */}}` | `{{/* <project>:<key>:end */}}` |
| YAML | `# <project>:<key>:start` | `# <project>:<key>:end` |
| Haskell / PureScript / TypeScript | `-- <project>:<key>:start` (or `//`) | mirror |

`<key>` is dotted, hierarchical, and unique across the registry — e.g.
`command-registry`, `route-registry.web-portal`, `route-registry.harbor`.

### Paired check and write commands

Every generated section has **both** commands:

- `tool docs check` (or `tool lint docs`) — read each rule, extract the slice between
  markers in the on-disk file, exact-string-compare to `expected`. Fail with the
  path, the offending marker key, and a remedy hint on mismatch.
- `tool docs generate` (or `tool docs check --write`, modeled on `gofmt -w` and
  `prettier --write`) — read each rule, splice `expected` between the markers in
  place, write the file back. Idempotent.

Both commands consume the same `GeneratedSectionRule` list. Implementing only the
validator is forbidden: a contributor who sees `"X has drifted"` with no way to fix it
will eventually disable the lint rather than fight the loop.

### Two categories of generation

1. **Partial generation.** A slice inside a hand-maintained file, delimited by markers.
   The surrounding prose is editable; the slice is not. Most documentation artifacts
   fit this category.
2. **Full generation.** The entire file is owned by code. No markers are needed; the
   file is listed in a separate "tracked-generated paths" registry that the
   `lint files` pass refuses to allow hand edits to. Examples: cross-language type
   bridges (PureScript / TypeScript contracts), proto-derived Haskell modules.

The two categories share the same renderer-as-source-of-truth principle but use
different enforcement mechanisms.

A third, complementary registry — the `forbiddenPathRegistry` — names paths
that must *not* exist. It uses the same data shape and the same error-message
contract as this section. See **Lint, Format, and Code-Quality Stack →
Forbidden Surfaces (Negative-Space Lint)**.

### Required error-message contract

When the validator fails, the message must include:

1. The file path that drifted.
2. The marker key (so the contributor knows which renderer is responsible).
3. A literal remedy hint, e.g. ``Run `tool docs generate` to update.``

Drift errors without a remedy hint are forbidden. The cost of writing the hint is
trivial; the cost of contributors not knowing what to do is permanent friction.

### Determinism requirements

Renderers must be pure functions of typed input. They must not embed:

- timestamps
- random IDs
- locale-dependent ordering (sort with an explicit comparator)
- terminal-width-dependent wrapping
- environment-dependent paths

Non-deterministic renderers turn `lint docs` into a flaky check, which destroys the
discipline. Golden tests already require this; the doctrine extends the requirement
to all generators.

### Extension protocol

Adding a new generated section is a five-step change in a single PR:

1. Define or extend the renderer in the relevant library module.
2. Add markers to the target file.
3. Register a new `GeneratedSectionRule`.
4. Run `tool docs generate` to populate the section.
5. Confirm `tool docs check` and `cabal test` pass.

### Project-level documentation standards

The doctrine cannot dictate every project's full standards document, but a project
that adopts this discipline must include the following in its
`documents/documentation_standards.md` (or equivalent canonical home):

1. **A "Generated Sections" subsection** stating the marker convention literally, with
   a worked example. Readers should learn the syntactic contract from this file
   alone, without grepping source.
2. **An authoritative list (or pointer) of files containing generated regions.**
   Either inline-enumerate them, or point at the `GeneratedSectionRule` table and
   require a lint check that the doc's list and the table agree.
3. **A "How to regenerate" instruction.** Name the writer command literally
   (`tool docs generate`). State that hand-editing inside the markers will be lost on
   the next regenerate and will fail `tool docs check` until reverted.
4. **A `**Generated sections**:` per-file metadata field.** The metadata block that
   already declares `**Status**` and `**Referenced by**` extends with a
   `**Generated sections**: <key1>, <key2>` line (or `none`). Lint enforces that any
   file with markers declares them in this field, and vice versa.
5. **A "How to add a new generated section" protocol** restating the five-step
   extension protocol for documentation contributors who do not need to read the full
   doctrine.
6. **A "Fully generated, do-not-hand-edit" rule** cross-referencing the
   tracked-generated-paths registry and listing the paths under that regime
   (cross-language type bridges, proto-derived modules, etc.). Hand edits to these
   paths are a lint failure with no override.

This makes "the documentation discipline is itself documented at the project level" a
property the doctrine checks for, not an aspiration.

---

## Architecture

The prescribed flow:

```text
CommandSpec
  -> parser generation
  -> documentation generation
  -> introspection generation
  -> Command
  -> runCommand
```

The module layout:

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

### Subprocesses as Typed Values

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
  (see **Plan / Apply** below).

**Forbidden patterns:**

- Calling `callProcess`, `readCreateProcess`, `System.Process` constructors, or
  `typed-process` smart constructors directly from a command runner. The two
  interpreter functions above are the only IO boundary for subprocess
  execution.
- Resolving paths, expanding env vars, or branching on the host inside the
  interpreter. The builder is total; the interpreter executes what it's given.
- Returning subprocess output through `IORef`, `MVar`, or other shared mutable
  state instead of the typed `ProcessOutput` record.

This subsection is the foundation for **Plan / Apply**: a `Plan` is typically
a tree, list, or DAG of `Subprocess` values.

---

## Smart Constructors for Paired Resources

When a system creates related resources that must stay consistent (e.g., a Kubernetes
PersistentVolume and its PersistentVolumeClaim, a database user and its grants, a queue
and its dead-letter queue), derive both resources from a single source of truth via a
smart constructor. The smart constructor guarantees consistency by construction — there
is no code path that can create one resource without creating its pair.

The prescribed shape:

```haskell
import Crypto.Hash (SHA256, Digest, hash)
import Data.ByteString.Char8 qualified as BS8
import Data.Text (Text)
import Data.Text qualified as T

-- | Kubernetes PersistentVolume (pre-provisioned)
data PlannedPV = PlannedPV
    { pvName :: Text
    , pvStorageClass :: Text
    , pvCapacity :: Text
    , pvAccessModes :: [Text]
    , pvClaimRef :: PVClaimRef
    }
    deriving stock (Show, Eq)

-- | Kubernetes PersistentVolumeClaim
data ExpectedPVC = ExpectedPVC
    { pvcName :: Text
    , pvcNamespace :: Text
    , pvcStorageClass :: Text
    , pvcCapacity :: Text
    , pvcAccessModes :: [Text]
    }
    deriving stock (Show, Eq)

-- | Claim reference embedded in PV
data PVClaimRef = PVClaimRef
    { claimName :: Text
    , claimNamespace :: Text
    }
    deriving stock (Show, Eq)

-- | Paired PV + PVC that are guaranteed to bind
data StorageBinding = StorageBinding
    { bindingPV :: PlannedPV
    , bindingPVC :: ExpectedPVC
    }
    deriving stock (Show, Eq)

-- | Smart constructor: both resources derived from same inputs
mkStorageBinding ::
    Text ->      -- namespace
    Text ->      -- release name
    Text ->      -- workload name
    Text ->      -- claim template name
    Int ->       -- ordinal (for StatefulSet replicas)
    Text ->      -- storage class
    Text ->      -- requested storage (e.g., "10Gi")
    [Text] ->    -- access modes
    StorageBinding
mkStorageBinding namespace release workload claimTemplate ordinal
                 storageClass capacity accessModes =
    let
        -- Derive names from consistent inputs
        baseName = T.intercalate "-"
            [claimTemplate, workload, T.pack (show ordinal)]
        pvcName = boundedResourceName namespace release baseName
        pvName = "pv-" <> hashSuffix (namespace <> "/" <> pvcName)
    in
        StorageBinding
            { bindingPV = PlannedPV
                { pvName = pvName
                , pvStorageClass = storageClass
                , pvCapacity = capacity
                , pvAccessModes = accessModes
                , pvClaimRef = PVClaimRef
                    { claimName = pvcName
                    , claimNamespace = namespace
                    }
                }
            , bindingPVC = ExpectedPVC
                { pvcName = pvcName
                , pvcNamespace = namespace
                , pvcStorageClass = storageClass
                , pvcCapacity = capacity
                , pvcAccessModes = accessModes
                }
            }
```

### Naming helpers for platform constraints

When resources have naming constraints (DNS-1123 labels, maximum lengths, character
restrictions), centralize enforcement in helper functions:

```haskell
-- | Enforce DNS-1123 label constraints (max 63 chars)
boundedResourceName :: Text -> Text -> Text -> Text
boundedResourceName namespace release base =
    let
        full = T.intercalate "-" [release, base]
        maxLen = 63
    in
        if T.length full <= maxLen
            then sanitizeResourceName full
            else
                let
                    suffix = hashSuffix full
                    truncated = T.take (maxLen - 1 - T.length suffix) full
                in
                    sanitizeResourceName (truncated <> "-" <> suffix)

-- | Replace invalid characters for DNS-1123
sanitizeResourceName :: Text -> Text
sanitizeResourceName = T.map sanitizeChar . T.toLower
  where
    sanitizeChar c
        | c >= 'a' && c <= 'z' = c
        | c >= '0' && c <= '9' = c
        | c == '-' = c
        | otherwise = '-'

-- | Short hash suffix for uniqueness
hashSuffix :: Text -> Text
hashSuffix input =
    T.take 8 . T.pack . show $
        (hash (BS8.pack (T.unpack input)) :: Digest SHA256)
```

**Forbidden patterns:**

- Constructing paired resources independently in separate code paths.
- Hardcoding resource names without platform constraint enforcement.
- Manual name synchronization between related resources.
- Length truncation without hash suffixes (collisions).

---

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

- **Prerequisites as Typed Effects** (below) runs before `apply`. A
  prerequisite failure aborts before any plan step executes.
- **Reconcilers** (further below) are a specialization: a reconciler is a
  Plan/Apply command whose `apply` is a no-op when current state already
  matches the plan's desired state.

---

## Output Rules

Use `stdout` for primary output:

```bash
tool users list --json > users.json
```

Use `stderr` for diagnostics:

```text
warning: config file not found, using defaults
error: user does not exist: alice
```

Support machine-readable output early:

```bash
tool users list --format json
tool users list --format table
tool users list --format plain
```

Avoid color unless writing to a terminal.

Provide:

```bash
--color auto
--color always
--color never
--no-color
```

These rules apply to short-running invocations. Long-running daemons follow the
structured-logging discipline in **Long-Running Daemons in the Same Binary**:
stderr receives JSON-formatted log lines; stdout is reserved for the daemon's
protocol surface or unused; `--format` and `--color` flags do not apply.

---

## Error Handling

Define domain-level errors:

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
which begins drain. See **Long-Running Daemons in the Same Binary → Error
handling: recoverable vs fatal**.

---

## Capability Classes and Service Errors

Subsystem boundaries (object storage, cache, database, message queue) are abstracted
through capability classes. Each subsystem has its own error newtype wrapping a unified
`ServiceError`, and a conversion typeclass enables generic handling (retry logic, unified
reporting) without coupling.

### Unified service error type

```haskell
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase #-}

import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Concurrent (threadDelay)
import Data.ByteString (ByteString)
import Data.Text (Text)

-- | Unified service error type
data ServiceError
    = SEConnectionFailed Text
    | SETimeout Text
    | SENotFound Text
    | SEPermissionDenied Text
    | SEConflict Text
    | SEInternalError Text
    deriving stock (Show, Eq)

-- | Subsystem-specific error newtypes
newtype MinIOError = MinIOError { unMinIOError :: ServiceError }
    deriving stock (Show, Eq)

newtype RedisError = RedisError { unRedisError :: ServiceError }
    deriving stock (Show, Eq)

newtype PgError = PgError { unPgError :: ServiceError }
    deriving stock (Show, Eq)
```

### Conversion typeclass

```haskell
-- | Conversion typeclass for unified handling
class AsServiceError e where
    toServiceError :: e -> ServiceError
    fromServiceError :: ServiceError -> e

instance AsServiceError MinIOError where
    toServiceError = unMinIOError
    fromServiceError = MinIOError

instance AsServiceError RedisError where
    toServiceError = unRedisError
    fromServiceError = RedisError

instance AsServiceError PgError where
    toServiceError = unPgError
    fromServiceError = PgError
```

### Capability classes

```haskell
-- | Capability class for object storage
class (Monad m) => HasMinIO m where
    minioPutObject ::
        BucketName -> ObjectKey -> ByteString -> m (Either MinIOError ())
    minioGetObject ::
        BucketName -> ObjectKey -> m (Either MinIOError (Maybe ByteString))
    minioDeleteObject ::
        BucketName -> ObjectKey -> m (Either MinIOError ())

-- | Capability class for cache
class (Monad m) => HasRedis m where
    redisGet :: RedisKey -> m (Either RedisError (Maybe ByteString))
    redisSet :: RedisKey -> ByteString -> TTLSeconds -> m (Either RedisError ())
    redisDelete :: RedisKey -> m (Either RedisError ())
```

### Generic retry across service errors

```haskell
-- | Generic retry that works across all service errors
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

---

## Retry Policy as First-Class Values

Retry policies are explicit typed values, not hardcoded loops with magic numbers. The
policy definition is separate from error classification.

```haskell
-- | Retry policy as an explicit value
data RetryPolicy = RetryPolicy
    { retryBaseDelayMicros :: Int
    , retryMaxDelayMicros :: Int
    , retryMaxAttempts :: Int
    }
    deriving stock (Show, Eq)

-- | Default policy: 10ms base, 1s max, 5 attempts
defaultRetryPolicy :: RetryPolicy
defaultRetryPolicy = RetryPolicy
    { retryBaseDelayMicros = 10_000
    , retryMaxDelayMicros = 1_000_000
    , retryMaxAttempts = 5
    }

-- | Pure exponential backoff calculation
retryDelayMicros :: RetryPolicy -> Int -> Int
retryDelayMicros policy attemptNumber =
    fromInteger $
        min (toInteger (retryMaxDelayMicros policy))
            (toInteger (retryBaseDelayMicros policy) *
             ((2 :: Integer) ^ max 0 (attemptNumber - 1)))

-- | Error classification: which errors are worth retrying?
serviceErrorRetryable :: ServiceError -> Bool
serviceErrorRetryable = \case
    SEConnectionFailed _ -> True   -- transient network issue
    SETimeout _ -> True            -- might succeed on retry
    SEConflict _ -> True           -- optimistic locking, retry may help
    SEInternalError _ -> True      -- server hiccup
    SENotFound _ -> False          -- won't magically appear
    SEPermissionDenied _ -> False  -- credentials won't change
```

Example delay sequence for the default policy:

```haskell
-- retryDelayMicros defaultRetryPolicy <$> [1..5]
-- => [10000, 20000, 40000, 80000, 160000]
```

**Forbidden patterns:**

- Hardcoded retry counts or delays in call sites.
- Retry logic without exponential backoff.
- Retrying non-retryable errors (not found, permission denied).
- Magic numbers for delay or attempt limits.

---

## Prerequisites as Typed Effects

Preconditions — required binaries on `$PATH`, valid credentials, reachable
endpoints, supported OS, required files on disk — are encoded as a typed
directed acyclic graph, not as scattered `unless (toolExists "kubectl") fail`
checks in command runners.

The prescribed three types:

```haskell
data Validation
  = RequireTool FilePath [Text]       -- binary + accepted version args
  | RequireFileExists FilePath
  | RequireEnvVar Text
  | RequireReachable URI
  | RequireOS SupportedOS
  -- ...extend per project
  deriving stock (Eq, Show)

data PrerequisiteNode = PrerequisiteNode
  { nodeId            :: Text
  , nodeDescription   :: Text
  , nodePrerequisites :: [Text]       -- IDs of dependency nodes
  , nodeCheck         :: Validation
  }

prerequisiteRegistry :: Map Text PrerequisiteNode
```

The registry is the single source of truth. Adding a prerequisite means adding
one entry to the map. Declaring a command's needs means listing the root IDs
that command depends on.

Expansion is pure:

```haskell
transitiveClosure
  :: [Text]                            -- root IDs
  -> Map Text PrerequisiteNode
  -> Either AppError [PrerequisiteNode]
```

Missing IDs are a registry error caught at expansion time, not at runtime, so
typos and stale references never reach an end user.

Interpretation lives at the IO boundary:

```haskell
checkPrerequisites
  :: Env
  -> [PrerequisiteNode]
  -> IO (Either PrerequisiteFailure ())
```

**Required error-message contract.** A prerequisite failure must include:

1. The failing `nodeId`.
2. The `nodeDescription`.
3. A remedy hint (install command, doc URL, configuration snippet).

This mirrors the **Required error-message contract** in **Generated Artifacts**.
Failures that name a problem but offer no remedy are forbidden in both lines
of discipline.

Where in the lifecycle:

- One-shot commands: `transitiveClosure` runs immediately before `apply` (see
  **Plan / Apply**). A single unmet prerequisite aborts with non-zero exit
  before any plan step executes.
- Daemons: the prereq DAG runs between `load` and `acquire` (see
  **Long-Running Daemons in the Same Binary → Lifecycle**). The daemon refuses
  to enter `acquire` if any node fails.

**Forbidden patterns:**

- Inline `unless` / `when` checks of prerequisite-shaped conditions in command
  runners. Add a registry node instead.
- Multiple registries (per-command, per-module). The single
  `Map Text PrerequisiteNode` is the source of truth.
- Silent fallback when a prerequisite is unmet. The command refuses to
  proceed; it does not paper over the gap.
- Checking prerequisites *after* a mutating step. The DAG is a gate, not a
  postflight check.

This section composes with **Plan / Apply** above (prereqs gate `apply`) and
**Reconcilers** below (prereqs gate every reconcile run).

---

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
**Long-Running Daemons in the Same Binary → The Env record grows** for the
prescribed baseline.

---

## Long-Running Daemons in the Same Binary

Many CLI tools also host long-running daemons. The doctrine prescribes hosting them
inside the same binary, launched and configured via the CLI surface.

### What carries over unchanged

Daemons share the same architectural spine as one-shot commands:

- Library-first project layout, thin `Main.hs`.
- Typed `Command` ADT — the daemon is launched by a `Command` constructor like
  any other (e.g. `ServiceCommand`, `DaemonStartCommand`).
- `CommandSpec` registry — daemon-launching commands appear in `tool --help` and
  generated docs like any other.
- Generated-artifacts discipline — daemon config schemas, route inventories, and
  generated CLI sections still go through the marker/registry pattern.
- Lint/format stack — applies to daemon code identically.
- `tool test all` runs daemon lifecycle tests alongside everything else.

What this section adds is the lifecycle, observability, configuration, and error
discipline that daemons require beyond short-running CLI.

### Same-binary policy

The CLI and its daemons live in one binary. Rationale:

- Single distribution artifact, single dependency closure.
- Shared types, config loader, logger, error type — no duplication.
- The CLI introspects the daemon's command surface, generates its docs, and runs
  its tests through the same machinery.
- Operators learn one binary, not two.

Tradeoffs to acknowledge:

- The binary's runtime dep closure includes daemon-only libraries (`warp`,
  message-broker clients, etc.) even for one-shot invocations.
- A bug in CLI plumbing can affect daemon startup, so the dispatch boundary
  between CLI handling and daemon entry is a clean typed function call.
- Test-time iteration is slower because every change rebuilds the whole binary.

### The daemon-as-Command pattern

A daemon is launched by a typed `Command` constructor that dispatches to a daemon
entry function:

```haskell
data Command
  = ...
  | ServiceCommand ServiceOptions
  | ...

runCommand :: Env -> Command -> IO ()
runCommand env = \case
  ...
  ServiceCommand opts -> Daemon.run env opts
  ...
```

Daemons do not have their own argv parser. CLI parsing is performed once, in the
same `optparse-applicative`-driven entry point used for every other command. The
daemon receives a parsed, typed options record plus the shared `Env`. Help,
completion, and introspection remain uniform.

### Lifecycle: load → prereq → acquire → ready → serve → drain → exit

Every daemon follows a seven-step lifecycle, expressed as nested `bracket` and
`withAsync`:

```text
1. Load and validate configuration   (fail fast on bad config)
2. Check prerequisites                (typed DAG; see Prerequisites as Typed Effects)
3. Acquire resources                  (bracket: open pools, connections, files)
4. Signal readiness                   (HTTP /readyz)
5. Serve / process                    (workers run inside withAsync)
6. Drain on shutdown signal           (SIGTERM/SIGINT triggers a TMVar)
7. Release resources and exit cleanly (bracket release runs in reverse order)
```

- **Configuration load** happens once at startup. Fail-fast on parse or validation
  error with a clear stderr message and non-zero exit. Daemons do not silently
  default away missing config.
- **Prerequisite check** runs the typed DAG defined in **Prerequisites as
  Typed Effects** between `load` and `acquire`. A single unmet node aborts
  before any resource is acquired.
- **Resource acquisition** uses `bracket` (or `bracketOnError`) so cleanup runs
  on every exit path, including exceptions. Resources with external side effects
  — DB connections, file locks, message-broker consumer registrations — are
  released even on crash.
- **Readiness signaling** is HTTP `/readyz`. Every daemon exposes it; it returns
  200 once startup completes and 503 during startup or drain. Filesystem
  readiness markers and `sd_notify(READY=1)` are forbidden. `threadDelay` "wait
  long enough" probes are forbidden. Polling logs for a ready string is
  forbidden.
- **Serving** uses `Control.Concurrent.Async` (`withAsync`, `race`,
  `concurrently`, `replicateConcurrently`). `forkIO` is forbidden in daemon
  code: it cannot be cancelled, cannot propagate exceptions, and leaks on
  shutdown.
- **Shutdown** is signal-driven. The daemon installs handlers for SIGTERM and
  SIGINT that fill a shared `TMVar ()`. The main loop and workers observe the
  signal via `race` or an STM `check`. SIGTERM begins a graceful drain; a
  second SIGTERM (or SIGKILL) terminates immediately.
- **Drain semantics**: stop accepting new work, finish in-flight requests up to
  a bounded deadline (default 30s), then close. Drain is bounded; an indefinite
  drain is a hang.

### Structured concurrency

- Use `Control.Concurrent.Async` (`withAsync`, `concurrently`, `race`,
  `replicateConcurrently`) for any work that outlives a single function call.
- Use `bracket` / `bracketOnError` for resource acquisition.
- `forkIO` is forbidden in daemon code.
- Worker loops that restart on transient error use a `try`/`catch` plus
  bounded retry-with-backoff wrapper, not naked `forever`.

### Error handling: recoverable vs fatal

The CLI doctrine's `AppError` ADT treats errors as terminal. Daemons add a
second axis:

```haskell
data AppError = AppError
  { errorKind  :: ErrorKind
  , errorMsg   :: Text
  , errorCause :: Maybe SomeException
  }

data ErrorKind
  = Recoverable   -- retry with backoff inside the worker loop
  | Fatal         -- propagate to top level, drain, exit non-zero
```

Worker loops handle `Recoverable` errors by logging at warn level and retrying
with exponential backoff (capped). `Fatal` errors propagate to the top-level
supervisor, which begins drain and exits. The distinction is made at the call
site that knows the context — not by inspecting exception types globally.

### Logging and observability

- Structured logging is mandatory for daemons. Logs go to stderr as JSON lines
  with timestamp, level, message, and a context bag. The doctrine prescribes
  `co-log` as the logger library. `putStrLn` is forbidden in daemon code paths.
- Log levels are first-class: `debug`, `info`, `warn`, `error`. Daemons start
  at `info` by default; the level is set by `BootConfig` at startup and
  refreshed from `LiveConfig` on every hot reload.
- The logger lives in `Env`. All daemon code paths take `MonadReader Env` (or
  receive `Env` explicitly) so log calls attach contextual fields without
  rethreading.
- Health endpoints. Every daemon exposes both:
  - `/healthz` (liveness) — 200 when the process is alive.
  - `/readyz` (readiness) — 200 only after startup completes; 503 during drain.
  These paths are specified literally so deployment tooling (Kubernetes,
  systemd, load balancers) probes uniformly.
- Metrics. Every daemon exposes `/metrics` in Prometheus exposition format.
  The doctrine does not pin a specific client library.

### Structured logging field helpers

The prescribed pattern for structured logging uses type-safe field construction:

```haskell
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Lazy.Char8 qualified as LBS8
import Data.Text (Text)
import Data.Time (getCurrentTime)
import Data.UUID (UUID)
import System.IO (stderr)

-- | Type-safe field construction
field :: (Aeson.ToJSON a) => Text -> a -> (Text, Aeson.Value)
field key value = (key, Aeson.toJSON value)

-- | Structured log output (JSON to stderr)
logStructured :: Text -> Text -> [(Text, Aeson.Value)] -> IO ()
logStructured level event details = do
    now <- getCurrentTime
    LBS8.hPutStrLn stderr . Aeson.encode . Aeson.Object $
        KeyMap.fromList
            [ (Key.fromText "timestamp", Aeson.toJSON now)
            , (Key.fromText "level", Aeson.toJSON level)
            , (Key.fromText "event", Aeson.toJSON event)
            , (Key.fromText "details", Aeson.Object $
                KeyMap.fromList $
                    fmap (\(k, v) -> (Key.fromText k, v)) details)
            ]

-- | Convenience wrappers
logDebug, logInfo, logWarn, logError :: Text -> [(Text, Aeson.Value)] -> IO ()
logDebug = logStructured "debug"
logInfo = logStructured "info"
logWarn = logStructured "warn"
logError = logStructured "error"
```

Usage:

```haskell
exampleUsage :: UUID -> Int -> IO ()
exampleUsage requestId itemCount = do
    logInfo "order_processing_started"
        [ field "request_id" requestId
        , field "item_count" itemCount
        , field "source" ("api" :: Text)
        ]
```

Output:

```json
{"timestamp":"2024-01-15T10:30:00Z","level":"info","event":"order_processing_started","details":{"request_id":"550e8400-e29b-41d4-a716-446655440000","item_count":3,"source":"api"}}
```

**Forbidden patterns:**

- `putStrLn` or `print` for logging in daemon code.
- Format strings (`printf`-style) instead of structured fields.
- Untyped field construction (`[("key", toJSON value)]` without the `field` helper).
- Logs to stdout (reserved for daemon protocol surfaces or unused).

### The Env record grows

For daemons the prescribed baseline `Env`:

```haskell
data Env = Env
  { envBootConfig :: BootConfig       -- immutable after startup
  , envLiveConfig :: TVar LiveConfig  -- hot-reloadable; see Configuration
  , envLogger     :: Logger           -- structured, level-aware
  , envMetrics    :: MetricsRegistry  -- typed
  , envShutdown   :: TMVar ()         -- signals graceful drain
  , envResources  :: Resources        -- pools, clients, broker handles
  }
```

`Env` is built once during the lifecycle's "acquire" phase, threaded via
`ReaderT Env IO`, and torn down in reverse order. Global `IORef`s for any of
these are forbidden — they belong in `Env`. The split between `envBootConfig`
(plain value) and `envLiveConfig` (`TVar`) is load-bearing: "which settings can
change at runtime" is a property of the Haskell type, not prose.

### Test hooks in Env

Test hooks are fields in the `Env` record that allow tests to observe or control async
behavior without mocking via typeclasses. Production environments use no-op hooks; tests
inject hooks to observe timing, trigger events, or control concurrency.

```haskell
import Control.Concurrent.STM (TVar, TMVar, newEmptyTMVarIO)
import Data.Map.Strict (Map)
import Data.UUID (UUID)

-- | Extended Env with test hooks
data Env = Env
    { envBootConfig :: BootConfig
    , envLiveConfig :: TVar LiveConfig
    , envLogger :: Logger
    , envMetrics :: MetricsRegistry
    , envShutdown :: TMVar ()
    , envResources :: Resources
    -- Test hooks (no-op in production)
    , envAfterConsumerClaim :: UUID -> IO ()
    , envBeforeMessageAck :: MessageId -> IO ()
    , envOnConnectionEstablished :: ConnectionId -> IO ()
    }

-- | Production environment with no-op hooks
mkProductionEnv :: BootConfig -> TVar LiveConfig -> Resources -> IO Env
mkProductionEnv bootConfig liveConfig resources = do
    logger <- mkLogger (bootLogLevel bootConfig)
    metrics <- mkMetricsRegistry
    shutdown <- newEmptyTMVarIO
    pure Env
        { envBootConfig = bootConfig
        , envLiveConfig = liveConfig
        , envLogger = logger
        , envMetrics = metrics
        , envShutdown = shutdown
        , envResources = resources
        -- No-op hooks for production
        , envAfterConsumerClaim = const (pure ())
        , envBeforeMessageAck = const (pure ())
        , envOnConnectionEstablished = const (pure ())
        }

-- | Test environment with injectable hooks
mkTestEnv ::
    BootConfig ->
    TVar LiveConfig ->
    Resources ->
    (UUID -> IO ()) ->         -- afterConsumerClaim hook
    (MessageId -> IO ()) ->    -- beforeMessageAck hook
    (ConnectionId -> IO ()) -> -- onConnectionEstablished hook
    IO Env
mkTestEnv bootConfig liveConfig resources afterClaim beforeAck onConn = do
    baseEnv <- mkProductionEnv bootConfig liveConfig resources
    pure baseEnv
        { envAfterConsumerClaim = afterClaim
        , envBeforeMessageAck = beforeAck
        , envOnConnectionEstablished = onConn
        }
```

Usage in application code:

```haskell
handleConsumerClaim :: Env -> UUID -> IO ()
handleConsumerClaim env consumerId = do
    -- ... actual claim logic ...
    registerConsumer (envResources env) consumerId
    -- Hook fires after the operation
    envAfterConsumerClaim env consumerId
```

**Forbidden patterns:**

- Mocking subsystem behavior via typeclasses when simple hooks suffice.
- Global `IORef`s for test coordination instead of `Env` fields.
- Hooks that change production behavior (all hooks must be no-ops in production).
- Tests that rely on `threadDelay` instead of hooks for timing.

### Configuration: Dhall file with mandatory hot reload

Configuration is a single `.dhall` file on the filesystem.

Why Dhall:

- Strong typing on the config side prevents silent schema drift between daemon
  versions.
- Imports and merges make large configs refactorable without giving up validation.
- Dhall is total — no IO, no surprises during evaluation — so reload is safe and
  predictable.
- The Haskell `dhall` package provides
  `Dhall.inputFile :: FromDhall a => Decoder a -> FilePath -> IO a` for typed
  decoding straight into the daemon's config record. No intermediate parser
  layer.

YAML, JSON, and TOML for daemon config are forbidden.

Hot reload is mandatory.

**Boot vs Live configuration.** Split the config record at compile time into two
sub-records, both decoded from the same Dhall file:

```haskell
data Config = Config
  { configBoot :: BootConfig
  , configLive :: LiveConfig
  }

data BootConfig = BootConfig
  { bootListenHost    :: Text
  , bootListenPort    :: Word16
  , bootConnPoolSize  :: Int
  , bootSchemaVersion :: Natural
  -- settings that cannot change without a restart
  }

data LiveConfig = LiveConfig
  { liveLogLevel     :: LogLevel
  , liveRateLimits   :: Map Text RateLimit
  , liveFeatureFlags :: Map Text Bool
  , liveRouting      :: RoutingTable
  -- settings safe to swap at runtime
  }
```

Only `LiveConfig` is hot-reloadable. Changes to `BootConfig` (listening port,
pool sizes, schema version, etc.) require a restart; the reload pass rejects
them: log at warn level, keep the old `BootConfig`, do not partially apply.
Reloads that change some `BootConfig` fields and not others are forbidden.

**Reload trigger.** SIGHUP is the single trigger. `kill -HUP <pid>` or
`systemctl reload <unit>` initiates a reload. The signal handler enqueues a
reload request onto a `TBQueue ()` consumed by a dedicated reload worker
spawned with `withAsync`; the handler itself does no parsing. `fsnotify`,
`inotify`, and any other file-watcher mechanism are forbidden. Polling the
file's `mtime` is forbidden.

**Reload procedure** (the dedicated reload worker):

```text
1. Read the config file path from BootConfig (set once at startup).
2. Call Dhall.inputFile to parse + type-check + decode in one step.
3. If parse/typecheck/decode fails: log warn with the Dhall error, keep current
   LiveConfig, emit a `config_reload_failed` log event. Daemon continues
   serving with the old config.
4. If decode succeeds but BootConfig fields differ from the running BootConfig:
   log warn that those changes are ignored until restart, emit a
   `config_boot_changes_ignored` event, keep current BootConfig, still apply
   the LiveConfig portion.
5. Validate the schema version field. On mismatch: same handling as step 3.
6. atomically (writeTVar envLiveConfig newLiveConfig).
7. Emit a `config_reloaded` log event with a structured diff summary (which
   top-level LiveConfig fields changed).
8. Publish on an STM broadcast channel (`TChan` or `TBQueue`) so subscribers
   that derive internal state from LiveConfig — rate limiters, routing
   caches — can refresh.
```

**Atomic swap discipline.** `envLiveConfig` is `TVar LiveConfig`. `IORef` for
live config is forbidden. Workers read from the `TVar` at the start of each
request or batch — caching the dereferenced value across an await/yield
boundary is forbidden, as it defeats the reload's atomicity. The reload is not
a stop-the-world operation; in-flight requests continue with whatever they
last read.

**Schema versioning.** The Dhall config has a top-level
`schemaVersion : Natural` field that the binary checks on every reload. A
version mismatch is treated like a parse failure: log warn, keep old config,
emit `config_schema_mismatch`. The schema version is part of `BootConfig` and
changes to it never take effect at runtime.

**Atomicity at the filesystem level.** Operators write the config file
atomically — write to a temp file, fsync, rename into place. The daemon does
not attempt to detect partial writes; Dhall's parse failure on malformed input
is the signal.

**Prescribed Dhall file shape.** The doctrine prescribes the following layout:

```dhall
let Types = ./types.dhall
let defaults = ./defaults.dhall
in defaults
  ⫽ { schemaVersion = 1
    , boot =
      { listenHost = "0.0.0.0"
      , listenPort = 8080
      , connPoolSize = 16
      }
    , live =
      { logLevel = Types.LogLevel.Info
      , featureFlags = toMap { newRouting = True }
      , routing = ./routing.dhall
      }
    }
```

`./types.dhall` and `./defaults.dhall` are committed to the repo and frozen
via `dhall freeze`; `./routing.dhall` is edited by operators in place. The
daemon decodes the merged record into the Haskell `Config` type via a derived
`FromDhall Config` instance.

**Forbidden patterns:**

- Env-var-driven config polling at request time.
- Mixing Dhall config with env-var or flag overrides for the same setting.
- Reloading by re-execing the binary.
- Hot-reloading anything in `BootConfig`.
- Polling `mtime` on the config file.

### CLI-to-daemon plumbing

Daemon-launching commands follow the same `CommandSpec` discipline as
everything else:

- A typed options record (`ServiceOptions`, `DaemonStartOptions`, etc.)
  populated by the `optparse-applicative` parser.
- Standard flags every daemon command accepts:
  - `--config <path>` — path to the `.dhall` config file. The daemon refuses
    to start if the path does not exist or does not parse.
  - `--log-level <level>` — startup default only; the Dhall file overrides
    this once read and continues to override across hot reloads.
  - `--port <int>` — startup-only override of the listening port; treated as
    a `BootConfig` default that the Dhall file replaces.
  - `--foreground` is the default. Self-daemonization (`--detach`) is
    forbidden; the supervisor (systemd, Kubernetes, Docker) owns the process
    model.
- Environment-variable overrides are limited to `BootConfig` startup defaults,
  namespaced `<PROJECT>_<SETTING>` (e.g. `MYTOOL_LOG_LEVEL`,
  `MYTOOL_CONFIG_PATH`). Precedence at startup: CLI flag > env var > Dhall
  file default > built-in default. Once the daemon is running, the Dhall file
  is the sole source of truth for `LiveConfig`.

### Daemon lifecycle tests

A dedicated test category: spawn the daemon as a subprocess via
`typed-process`, poll `/readyz` until ready, exercise the protocol surface,
send SIGTERM, assert graceful shutdown within the configured drain deadline,
assert exit code 0. Forbidden test patterns:

- `terminateProcess` without first attempting graceful shutdown.
- `threadDelay`-based readiness probes.
- Polling for filesystem readiness markers when `/readyz` exists.

Health-endpoint response shapes (`/healthz`, `/readyz`, `/metrics`) belong in
the golden-test category. Shutdown signal tests assert that a single SIGTERM
begins drain and a second SIGTERM (or timeout) forces exit.

---

## At-Least-Once Event Processing

Event-driven systems require idempotent handlers and explicit delivery tracking.
Events are immutable records stored with timestamps; a `processed_at` column tracks
which events have been handled.

### Event storage

```haskell
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}

import Data.Aeson (ToJSON, FromJSON, Value, encode)
import Data.Time (UTCTime)
import Data.UUID (UUID)
import Database.PostgreSQL.Simple (Connection, execute, query)
import GHC.Generics (Generic)

-- | Event types for a domain
data EventType
    = OrderCreated
    | OrderSubmitted
    | OrderApproved
    | OrderFulfilled
    | OrderCancelled
    deriving stock (Show, Eq, Generic)
    deriving anyclass (ToJSON, FromJSON)

-- | Persisted event record
data StoredEvent = StoredEvent
    { eventId :: UUID
    , eventAggregateId :: UUID
    , eventType :: EventType
    , eventPayload :: Value
    , eventCreatedAt :: UTCTime
    , eventProcessedAt :: Maybe UTCTime
    }
    deriving stock (Show, Eq, Generic)
```

### Recording and marking events

```haskell
-- | Record an event (immutable insert)
recordEvent ::
    Connection ->
    UUID ->           -- aggregate ID
    EventType ->
    Value ->          -- payload
    IO ()
recordEvent conn aggregateId eventType payload = do
    _ <- execute conn
        "INSERT INTO domain_events \
        \(aggregate_id, event_type, payload, created_at) \
        \VALUES (?, ?, ?, clock_timestamp())"
        (aggregateId, show eventType, encode payload)
    pure ()

-- | Mark event as processed (idempotent)
markEventProcessed :: Connection -> UUID -> IO ()
markEventProcessed conn eventId = do
    _ <- execute conn
        "UPDATE domain_events \
        \SET processed_at = clock_timestamp() \
        \WHERE id = ? AND processed_at IS NULL"
        [eventId]
    pure ()

-- | Fetch unprocessed events for replay
fetchUnprocessedEvents :: Connection -> IO [StoredEvent]
fetchUnprocessedEvents conn =
    query conn
        "SELECT id, aggregate_id, event_type, payload, created_at, processed_at \
        \FROM domain_events \
        \WHERE processed_at IS NULL \
        \ORDER BY created_at ASC"
        ()
```

### Idempotent event handlers

```haskell
{- | Handler for processing a single event.

INVARIANT: Handlers MUST be idempotent.

The same event may be delivered multiple times due to:
- Process crash after handling but before marking processed
- Network partition during acknowledgment
- Explicit replay for recovery

Idempotency strategies:
- Use database constraints (unique keys on natural identifiers)
- Check-then-act with the event ID as a deduplication key
- Design handlers as pure projections of event data
-}
type EventHandler = StoredEvent -> IO ()

-- | Process events with at-least-once delivery
processEvents :: Connection -> EventHandler -> IO ()
processEvents conn handler = do
    events <- fetchUnprocessedEvents conn
    for_ events $ \event -> do
        handler event  -- MUST be idempotent
        markEventProcessed conn (eventId event)
```

**Forbidden patterns:**

- Event handlers with non-idempotent side effects (sending emails, charging cards)
  without deduplication.
- Events stored without creation timestamps.
- Missing `processed_at` column (no way to track delivery state).
- Event ordering other than `created_at ASC` (breaks replay semantics).
- Deleting events after processing (audit trail loss).

---

## Reconcilers: Idempotent Mutation as a Single Command

Tools that manage state in the world expose a single canonical reconcile
command. Re-running it is a no-op when current state already matches desired
state. There is no separate `install` / `upgrade` / `repair` / `force-install`
split — those are different verbs for the same underlying operation.

Standard shape:

```haskell
data Command
  = ...
  | Reconcile ReconcileOptions
  | ...
```

Internally the reconcile is composed of independently idempotent steps. Each
step is safe to skip when its postcondition is already satisfied, and safe to
run when it is not.

Composition with prior sections:

- **Plan / Apply.** A reconcile is built as a Plan/Apply pair. `build` reads
  current state, computes the diff against desired state, and emits a plan
  listing only the steps that still need to run. An empty plan is the steady
  state and `apply` is a no-op.
- **Prerequisites as Typed Effects.** The prerequisite DAG runs before any
  mutating step. A reconcile on a host missing required tools or credentials
  fails fast at the gate.
- `--dry-run` prints the plan and exits. This is the operator's contract for
  "what will change if I run this against this host."

A worked example: a hypothetical reconcile that provisions a local
systemd-managed service.

```text
Step 1: install package    -- skip if package already at target version
Step 2: write config       -- skip if on-disk config matches desired content
Step 3: enable unit        -- skip if `systemctl is-enabled` returns enabled
Step 4: start unit         -- skip if `systemctl is-active` returns active
Step 5: assert healthy     -- always run; fail the reconcile if unhealthy
```

Each step is checked-before-mutated. Re-running the command performs zero
work when the system is already in the desired state.

**Forbidden patterns:**

- Sister commands like `install` / `upgrade` / `repair` / `force-install`.
  If the reconcile is correct, repeating it is the repair.
- `--force`, `--reinstall`, or any flag whose purpose is "ignore that the
  step is already done." The check-then-mutate discipline replaces this.
- Steps that mutate before checking their own postcondition. Mutation without
  a precondition check leaks work into the steady state.
- Steps that exit non-zero with an "already installed" error. Already-installed
  is the success case, not a failure.
- Reconcilers that mutate state not described in the plan. The plan is the
  audit trail of what will change.

Operators run the reconcile freely. When a tool publishes a reconcile
command, that command is the canonical mutation entrypoint, and running it on
a host — whether to bring up fresh state, reconcile drift, or recover from
partial state — is the supported operation, not an unauthorized change.

---

## Lint, Format, and Code-Quality Stack

The testing doctrine below defines how tests are structured. This section defines how
formatting, linting, and per-artifact code-quality enforcement are structured.

### Standard tools

| Tool | Role |
|---|---|
| `fourmolu` | Haskell source formatter — canonical format with configurable column limit |
| `hlint` | Haskell linter — code-smell detection, including project-defined nesting hints |
| `cabal format` | Cabal manifest formatter — single canonical layout for `.cabal` |
| `<project>.Lint.Files` | Trailing whitespace, final newline, blocked tracked-generated paths |
| `<project>.Lint.Docs` | Governed-document metadata, relative links, generated-section drift |
| `<project>.Lint.Proto` (if applicable) | Wire-format schema invariants |
| `<project>.Lint.Chart` (if applicable) | Helm chart structural invariants |

`fourmolu` is the formatter. The readability subsection below leans on its
`column-limit` setting; substituting another formatter is not offered.

### Tool bootstrap

`fourmolu` and `hlint` are installed by the lint pass itself to a pinned-GHC build
directory under `.build/<project>-style-tools/bin/`, via `ghcup run` + `cabal install`.
The pinned GHC version is declared in source (single constant) and isolated from the
project's main compiler so formatting is reproducible across contributors and CI. The
`.cabal` file is round-tripped through `cabal format` via a temp file and compared for
byte-equality (no in-place rewrite during check).

### Pinned `fourmolu.yaml`

A repo-root `fourmolu.yaml` is required and is part of the doctrine's reproducibility
contract. Minimum settings:

```yaml
indentation: 2
column-limit: 100
function-arrows: leading
comma-style: leading
import-export-style: leading
indent-wheres: false
record-brace-space: true
newlines-between-decls: 1
haddock-style: single-line
let-style: auto
in-style: right-align
unicode: never
respectful: true
```

The exact values are negotiable per-project; what the doctrine fixes is that the file
exists, is committed, and `column-limit` is set to a finite value. An unset or
infinite column limit defeats the readability proxy described below.

### CLI surface

The lint stack is exposed as per-artifact subcommands plus an aggregate:

```text
tool lint files       — whitespace / newline / tracked-generated / forbidden paths
tool lint docs        — governed docs, generated sections
tool lint proto       — wire-format schemas       (when proto present)
tool lint chart       — Helm chart invariants     (when chart present)
tool lint haskell     — fourmolu --mode check + hlint + cabal format roundtrip
tool lint all         — runs every lint above, plus `cabal build all`
```

### Forbidden Surfaces (Negative-Space Lint)

The lint stack enforces both that required artifacts are correct *and* that
parallel-workflow surfaces are absent. Drift *away* from the canonical
entrypoints is itself a lint failure.

A `forbiddenPathRegistry :: [PathPattern]` is the single source of truth for
disallowed paths. Same shape and discipline as the tracked-generated-paths
registry from **Generated Artifacts**: a Haskell list, committed to source,
consumed by `tool lint files`.

`tool lint files` extends its existing duties (trailing whitespace, final
newline, tracked-generated paths) with one more: refuse to allow any file
matching a forbidden pattern.

Default forbidden patterns every project rejects unless explicitly opted out:

- `.github/workflows/` — CI lives in `tool lint all` and `cabal test`, not in
  a parallel CI surface. Projects that publish via GitHub Actions opt in by
  registering a narrow exception (specific workflow files), not by removing
  the default.
- `.husky/`, `.githooks/`, `.pre-commit-config.yaml`, `pre-commit-*.yaml` —
  Git hooks are not the canonical lint surface. Style enforcement lives in
  `tool lint haskell` and the `<project>-haskell-style` test-suite.
- Project-level `Makefile`, `justfile`, `Taskfile.yml` that duplicate
  commands the tool already exposes. A wrapper that adds nothing is a drift
  vector.

**Error-message contract.** On a forbidden-path hit, the failure must
include:

1. The file path that matched.
2. The registry key (the pattern that matched).
3. A remedy hint of the form ``"delete this path; the canonical equivalent is
   `tool <command>`"``.

Identical contract to **Generated Artifacts → Required error-message
contract**. Drift errors without a remedy hint are forbidden in both lines.

This subsection is the negative-space counterpart to the tracked-generated-
paths registry in **Generated Artifacts → Two categories of generation**. The
tracked-generated registry says "these paths exist and must match the
renderer"; the forbidden-path registry says "these paths must not exist at
all." Same machinery, opposite polarity.

### Paired check and write semantics

Every check command must have a `--write` counterpart (or sibling command) that fixes
what can be auto-fixed:

- `tool lint files --write` strips trailing whitespace, adds final newlines.
- `tool lint docs --write` regenerates marker-delimited sections (equivalent to
  `tool docs generate`).
- `tool lint haskell --write` runs `fourmolu --mode inplace` and `cabal format` in
  place. hlint hints stay advisory; the contributor is responsible for restructuring.

### Style as a Cabal test-suite

The Haskell-style check is exposed both as the CLI command above and as a separate
`test-suite <project>-haskell-style` with `type: exitcode-stdio-1.0`. `cabal test`
runs it as part of the normal test surface, so style enforcement does not require a
separate developer workflow, a Makefile, or a pre-commit hook. The CLI command and
the test-suite call the same Haskell function.

### Aggregate dispatch

- `tool test lint` (or `tool lint all`) runs the full lint surface plus
  `cabal build all`.
- `tool test all` includes `tool test lint` as its first step before running
  `cabal test`.

### Readability and nesting

The doctrine states a readability goal, then identifies what can be automated about
it.

> Avoid nested case / if / lambda chains that push structural keywords far to the
> right. Prefer extracting helper bindings, pattern-matching at the function head,
> using guards, or returning early via `let` / `where`. Two levels of `case` is a
> code smell worth examining; three or more should be refactored.

Automated enforcement is partial:

1. **Column limit (primary lever).** `fourmolu.yaml` sets `column-limit: 100`. A
   four-deep `case` typically cannot wrap to satisfy this limit without becoming
   visually painful, which pressures authors to refactor. This is an indirect proxy
   — a deeply nested expression with short identifiers can still satisfy the limit
   — but it catches the common case at zero ongoing cost.
2. **Existing hlint hints (free wins).** Several built-in hlint hints already reduce
   nesting in common shapes and must remain enabled: `Use guards`, `Redundant case`,
   `Use let`, `Eta reduce`, `Avoid lambda`, `Use bracket`, `Use when`, `Use unless`.
   Run hlint in `--with-group=default` plus `--with-group=extra`.
3. **Project-specific hlint custom warnings.** `.hlint.yaml` accumulates custom
   warning rules for nesting anti-patterns observed in code review:
   ```yaml
   - warn:
       name: Refactor nested case
       lhs: "case x of _ -> case y of _ -> z"
       rhs: "(refactor: extract or combine)"
   - warn:
       name: Avoid case inside lambda body
       lhs: "\\x -> case y of _ -> z"
       rhs: "(refactor: pattern-match at the function head)"
   ```
   These rules are brittle — each matches only what it literally describes — but
   cheap to add as anti-patterns surface. Accumulate them rather than aspiring to a
   comprehensive list up-front.
4. **Code-review checklist.** A single-line review check: *"Does any function exceed
   two levels of nested case/if? If so, can it be flattened?"* This is the
   un-automated half of the discipline and is intentionally retained — column limit
   plus hlint hints catch most violations, review catches the rest.

The doctrine does not include strict AST-based nesting enforcement. Reasons: (a)
`ghc-lib-parser` is a heavyweight dependency tracking GHC's internal API, (b) the
column-limit plus hlint combination catches most pathological cases, (c) strict
depth enforcement creates churn around legitimate exceptions — parser combinators,
deeply structured ADT pattern matches — that are awkward to express as a budgeted
exception. The discipline stops at column limit, hlint hints, and the review
checklist.

---

## Testing Doctrine

The canonical developer-facing test command is:

```bash
tool test all
```

The canonical package-level test command is:

```bash
cabal test
```

`tool test all` must delegate to:

```bash
cabal test
```

via subprocess execution.

There must not be multiple independent test systems.

The CLI-level test command is a convenience and orchestration layer over Cabal rather than a replacement for Cabal.

Running either:

```bash
tool test all
```

or:

```bash
cabal test
```

must execute the complete test suite.

The complete test suite includes:

- pure logic tests
- parser tests
- property tests
- golden tests
- local integration tests
- Pulumi-orchestrated infrastructure tests
- lint and style checks (per-artifact lints plus the Haskell-style suite)

There should be no separate developer workflow for cloud-backed tests.

The full test suite is the canonical validation path.

Lint and style checks are part of the canonical test suite rather than a parallel
CI-only workflow. The `<project>-haskell-style` `test-suite` stanza makes `cabal test`
self-sufficient for style enforcement, so contributors and CI run the same command and
fail in the same way.

---

## Standard Testing Stack

All projects standardize on:

```text
Cabal
+ exitcode-stdio-1.0
+ tasty
+ tasty-hunit
+ tasty-quickcheck
+ tasty-golden
+ typed-process
+ temporary
+ Pulumi
+ fourmolu
+ hlint
+ cabal format
```

Responsibilities:

| Component | Responsibility |
|---|---|
| Cabal | Build and execute test suites |
| exitcode-stdio-1.0 | Standard test process interface |
| tasty | Unified test runner and organization |
| tasty-hunit | Assertions |
| tasty-quickcheck | Property testing |
| tasty-golden | Golden/snapshot testing |
| typed-process | CLI subprocess execution |
| temporary | Temporary directories/files |
| Pulumi | Infrastructure orchestration and teardown |
| fourmolu | Haskell source formatter (with configurable column limit) |
| hlint | Haskell linter (default + extra hint groups + project rules) |
| cabal format | Cabal manifest formatter (round-trip equality check) |

No alternative testing stack should be introduced without strong justification.

---

## Test Categories

### Pure Logic Tests

Pure business logic should be tested directly.

These tests should avoid IO whenever possible.

Example targets:

- configuration merging
- command planning
- rendering logic
- validation rules
- serialization behavior

---

### Parser Tests

Parser tests verify:

```text
argv
  -> Command ADT
```

The parser layer is real application logic and should be tested explicitly.

Examples:

```text
tool users create alice
  -> UsersCreate "alice"

tool users list --json
  -> UsersList JsonOutput
```

Parser tests should use `execParserPure` or equivalent parser-level APIs rather than spawning subprocesses.

---

### Property Tests

Use `tasty-quickcheck` for property testing.

Property tests are appropriate for:

- parsers
- serialization
- normalization
- transformations
- formatting invariants

Example properties:

```text
decode . encode == id
render is deterministic
parser roundtrips
```

---

### Golden Tests

Golden tests compare current output against committed reference output.

They are especially valuable for CLI tooling because CLIs generate large amounts of structured text.

Typical golden-test targets:

```text
tool --help
tool users --help
tool commands --tree
tool commands --json
generated Markdown docs
generated manpages
```

Golden tests make accidental CLI surface changes visible in diffs.

Golden outputs must be deterministic.

Avoid embedding:

- timestamps
- random IDs
- nondeterministic ordering
- terminal-width-dependent wrapping

---

### Integration Tests

Integration tests execute the real CLI binary as a subprocess.

Use `typed-process` for subprocess management.

Typical integration-test targets:

```text
stdin/stdout behavior
filesystem interactions
config loading
subprocess execution
exit codes
JSON output behavior
```

These tests validate the real executable boundary.

---

### Pulumi-Orchestrated Infrastructure Tests

Infrastructure tests provision real infrastructure using Pulumi, execute tests against deployed systems, then destroy all resources.

Pulumi owns infrastructure lifecycle management:

```text
create stack
  -> pulumi up
  -> run tests
  -> pulumi destroy
  -> pulumi stack rm
```

These tests validate real deployment assumptions and operational correctness.

Infrastructure tests should:

- use isolated ephemeral stacks
- generate unique stack names per run
- aggressively tag all infrastructure
- always perform teardown
- use `bracket`, `finally`, or equivalent structured cleanup

Infrastructure orchestration should remain outside core business logic.

Pulumi outputs should be treated as the contract between infrastructure provisioning and test execution.

---

### Daemon Lifecycle Tests

When the binary hosts a long-running daemon, lifecycle tests live in their own
`test-suite <project>-daemon-lifecycle` stanza. Each test spawns the daemon as
a subprocess via `typed-process`, polls `/readyz` until ready, exercises the
protocol surface, sends SIGTERM, asserts graceful shutdown within the
configured drain deadline, and asserts exit code 0.

Health-endpoint response shapes (`/healthz`, `/readyz`, `/metrics`) belong in
the golden-test category. Shutdown signal tests assert that a single SIGTERM
begins drain and a second SIGTERM (or timeout) forces exit.

Forbidden test patterns: `terminateProcess` without first attempting graceful
shutdown, `threadDelay`-based readiness probes, polling for filesystem
readiness markers when `/readyz` exists.

See **Long-Running Daemons in the Same Binary** for the lifecycle these tests
validate.

---

## Test Organization

Each test tier is a separate Cabal `test-suite` stanza with
`type: exitcode-stdio-1.0`:

```text
test-suite <project>-unit
test-suite <project>-integration
test-suite <project>-haskell-style
test-suite <project>-daemon-lifecycle  (when the binary hosts a daemon)
test-suite <project>-pulumi            (when infrastructure tests apply)
```

`cabal test` runs every stanza. A single `tasty` tree spanning all tiers is
forbidden: separate stanzas give Cabal-native parallelism, let CI and developers
target one tier (`cabal test <project>-unit`), and isolate dependency creep so
heavy integration deps do not leak into the unit suite.

Each stanza's `main-is` is a small `Main.hs` that calls into a library module
where the actual tests live; tasty (or HUnit / QuickCheck used directly) builds
the in-stanza test tree.

---

## The Architecture

Every project under this doctrine is built as:

```text
GHC 9.14.1
Cabal 3.16.1.0
+ exitcode-stdio-1.0
+ optparse-applicative
+ library-first project structure
+ thin Main.hs
+ typed Command ADTs
+ GADT-indexed state machines for workflows with >2 states; compile-time transition enforcement
+ existential wrapping with singletons for runtime-loaded typed values
+ smart constructors for paired/related resources; consistency by construction
+ subprocesses modeled as typed Subprocess values, interpreted at the boundary
+ explicit command introspection
+ first-class CommandSpec
+ Plan / Apply split: pure builder + effectful interpreter on every state-changing command
+ --dry-run on every Plan/Apply command
+ prerequisites encoded as a typed DAG with a single prerequisiteRegistry
+ transitive-closure expansion gates apply, and gates daemon acquire
+ capability classes for subsystem boundaries (HasMinIO, HasRedis, etc.)
+ service-specific error newtypes wrapping unified ServiceError
+ AsServiceError typeclass for generic retry and error handling
+ retry policy as first-class values; pure backoff calculation; explicit error classification
+ tasty
+ tasty-hunit
+ tasty-quickcheck
+ tasty-golden
+ typed-process
+ Pulumi-orchestrated infrastructure tests
+ first-class `lint <target>` and `docs {check,generate}` commands
+ paired check/write semantics on every validator
+ a GeneratedSectionRule registry as the single source of truth for both
+ a forbiddenPathRegistry; parallel-workflow surfaces (custom CI, hook directories) are a lint failure
+ fourmolu + hlint + cabal format as the standard code-quality stack
+ a committed fourmolu.yaml pinning column-limit and other formatting options
+ tool-bootstrapped formatter binaries pinned to a fixed GHC version
+ haskell-style enforcement exposed as both `tool lint haskell` and a
  <project>-haskell-style cabal test-suite
+ a stated readability/nesting goal backed by the column limit and hlint hints
+ daemons live in the same binary, launched by typed Command variants
+ daemon lifecycle: load → prereq → acquire → ready → serve → drain → exit, via bracket + withAsync
+ structured concurrency (Control.Concurrent.Async); no raw forkIO in daemons
+ SIGTERM/SIGINT install a shutdown TMVar; bounded graceful drain
+ HTTP /healthz, /readyz, and /metrics endpoints on every daemon
+ structured JSON logging on stderr with typed field helpers; co-log
+ Dhall configuration files, decoded straight into typed Haskell records
+ Config split into BootConfig (immutable) and LiveConfig (hot-reloadable via TVar)
+ SIGHUP triggers hot reload of LiveConfig; BootConfig changes require restart
+ schemaVersion field on the Dhall config; mismatch keeps the running config
+ Env holds logger, metrics, shutdown signal, resource handles, and test hooks
+ test hooks in Env for deterministic async testing; no-op in production
+ recoverable vs fatal error kinds with backoff for the former
+ at-least-once event processing with idempotent handlers and processed_at tracking
+ reconcilers as the canonical mutation entrypoint; no install/upgrade/repair split
+ daemon lifecycle tests as a distinct cabal test-suite stanza
```

`CommandSpec` is the canonical source of truth for:

- parser generation
- help generation
- documentation generation
- introspection
- shell completion
- JSON command schemas
