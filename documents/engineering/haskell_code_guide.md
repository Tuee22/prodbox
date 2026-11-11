# Haskell Code Guide

**Status**: Authoritative source
**Supersedes**: N/A
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
- spawned-handle disposition over every module under `src/`: a long-lived child's `Async` handle is
  linked or joined, never discarded. See
  [Chaos Hardening Doctrine, rule R6](./chaos_hardening_doctrine.md), whose enforcement paragraph
  owns the rule's exact scope, and `Prodbox.Supervision`, whose private constructor makes the
  unsupervised state unconstructible
- Fourmolu formatting through the checked-in [`fourmolu.yaml`](../../fourmolu.yaml)
- HLint through the checked-in [`/.hlint.yaml`](../../.hlint.yaml)
- warning-clean Haskell compilation through
  `cabal build --builddir=.build all --enable-tests --ghc-options=-Werror`
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

Fixed inspection-schema staging keeps declaration compilation, semantic marking and literal
generation pure. `CanonicalDhallValueShape.Stage` is the build-only Template Haskell boundary:
it registers Haskell source and package-manifest dependencies and translates structured
preparation/discovery failures into compiler errors. It reads no runtime configuration or secrets.
Generated runtime metadata contains strict constructor trees and a separately queryable numeric
data floor. Runtime value codecs and semantic validation retain their own existing owners.
`CanonicalDhallValueShape.BoundedStage` additionally certifies finite structural counts during
compilation and exposes an opaque nominal newtype. The runtime erases that wrapper; it is neither
a byte-budget proof nor a capability to perform effects.

### 2.3 Shared Runtime Foundations

The current supported worktree has started converging on a small shared foundation layer:

- `src/Prodbox/Subprocess.hs` owns structured subprocess construction and the `runStreaming` /
  `capture` interpreter boundary. Ordinary captured, bounded and background paths use
  `typed-process`; the kernel-owned bounded path uses its trusted fork/Go/exec protocol there.
  Interactive streaming uses `process` so its calling thread owns delegated Ctrl-C exit observation.
- Its package-private `SystemdBus`, `SystemdIdentity`, `KernelScope`, `ScopeFamily` and `HostOperationFamily` companions
  own explicit local manager transport, bounded invocation identifiers and direct-child scope observations.
  Alarm retirement requires terminal kernel membership, exact invocation-qualified timer stop,
  an inactive/no-job barrier and helper settlement; closing family absence follows reference release.
  Exact manager/child/invocation/membership checks precede cgroup descriptor use; held descriptors,
  filesystem and memory/PID observations remain coupled through a bounded handle lease. These
  primitives issue neither host-placement permits nor child-lifecycle completion receipts.
  The fixed scope/timer/no-op helper request permits one create attempt and keeps the original
  absolute expiry. Borrowed request/grace deadlines can only shorten the manager bound. Complete
  family inventory distinguishes absent, present without an invocation, and unobservable units.
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
- Long-running runtimes use structured concurrency and a proof-carrying shutdown result. A bounded
  cancellation or join may return `ShutdownIncomplete`; callers must not discard that result or
  publish `Stopped`. Terminal completion requires joined children, resolved waiters, and an empty
  owned-resource postcondition. The Bootstrap Broker contract is authoritative in
  [Lifecycle Control-Plane Architecture §7.1](./lifecycle_control_plane_architecture.md#71-shutdown-completion-is-proof-carrying).
  **Enforcement (Sprint `2.134`, 2026-09-11): a type above a gate.** `Prodbox.Supervision` is the
  only constructor for a long-lived child, and both of its combinators link before the handle value
  exists, so a spawned-but-unobserved child is unconstructible rather than discouraged.
  `checkSpawnedHandleDisposition` refuses a spawned `Async` handle that is neither linked nor joined
  anywhere under `src/`, with no admission registry. The gate decides whether a handle is disposed
  of, never when, so the proof-carrying half of this bullet above remains review guidance.
- **A credential handed to a subprocess needs a delivery mechanism with a proof obligation.** Passing
  a secret by a side channel — a named pipe, an inherited descriptor, a file the child is told to
  read — is a rendezvous, and a rendezvous either happened or did not. If the mechanism's success is
  not a value the caller holds, the caller cannot tell a delivered credential from an undelivered
  one, and neither can a test. The 2026-09-11 counterexample
  `CASCADE-QUALIFICATION-EPHEMERAL-KUBECTL-TOKEN-FIFO-UNSERVED-2026-09-11` is the worked instance:
  a bearer token served through a FIFO by a background writer that died before the child started,
  unobserved, on every run for weeks. Prefer a mechanism whose failure is a typed result at the
  boundary; where that is impossible, the client must not be constructible until delivery has been
  proven once. Sprint `7.39` repaired that instance the second way: the credential is written to a
  private file and read back before the client value exists, so "client alive, credential
  unreadable" is not a representable state.
- **Measure how many times the child reads before choosing between a stream and a file.** That
  number is the whole difference between the two, and it is not derivable from the interface. A
  rendezvous must serve the credential once per read, to a reader whose arrival it cannot observe
  and whose count it cannot know; a file serves any number of reads and cares about none of them.
  `kubectl` v1.35.8 was measured under `strace` opening its `tokenFile` exactly twice per
  invocation, independently of how many API requests that invocation makes — which is why the
  replacement above is a file. Design arguments about where a secret may live are settled second,
  after the reader's behaviour is known, because a mechanism the reader wedges on protects nothing.

These modules are closed doctrine-adoption surfaces. New code should prefer them over ad-hoc
reimplementations.

## 3. Repository-Owned Inputs

The current repository-owned Haskell style and lint inputs are:

- [`fourmolu.yaml`](../../fourmolu.yaml) for formatting
- [`.hlint.yaml`](../../.hlint.yaml) for lint **suppressions** — it carries no rules of its own
- [`.editorconfig`](../../.editorconfig) for editor ergonomics only

Important distinction:

- `fourmolu.yaml` is a hard-gate input
- `.hlint.yaml` is a hard-gate **suppression** input. **Corrected 2026-09-11 (Sprint `0.33`):** it
  holds zero custom hints and only `ignore:` entries, so it subtracts from the gate rather than
  adding to it. HLint itself still gates, through its `default` and `extra` groups. The check that
  read the file verified only that a comment block existed, and Sprint `2.134` retired it together
  with the marker block and the style-suite case that asserted the same markers
- `.editorconfig` is not a build-acceptance input

## 4. Canonical Commands

The authoritative mechanical Haskell quality gate is:

```bash
prodbox dev check
```

`src/Prodbox/CheckCode.hs` owns that command. The supported gate currently requires:

1. file/doctrine, governed-document, Haskell-format/lint, and chart lint stages
2. `cabal build --builddir=.build all --enable-tests --ghc-options=-Werror`
3. sync of the built operator binary to `.build/prodbox`

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

Long-running killable children start in a fresh POSIX session. Their timeout and cancellation stop
records descendants before signalling the parent, verifies PID/start-time identities before
signalling descendants across process groups, and confirms them within the shared stop deadline.
An unobservable identity or unconfirmed stop returns a structured error. Process ownership comes
from the child created by the interpreter; callers do not supply host process IDs.

`captureOwnedSubprocess` is the bounded-output alternative for a child whose cleanup must fit
inside its caller's remaining budget. Its opaque validated limits reserve graceful termination,
kill confirmation and reader settlement before work starts. Work stops at the earlier work
deadline; cleanup cannot acquire a fresh allowance beyond the original total monotonic deadline.
Readers enforce independent byte ceilings and are cancelled and joined on every exit. A trusted
child waits under the original nonblocking gate deadline until its mandatory PIDFD and kernel
scope are admitted. Parent-death and post-token/pre-exec clock checks protect startup. The owner
confirms kernel-group emptiness, retires its exact timer/helper family and reads all three roles
absent before reader settlement, including normal leader exit. CPU, memory and PID wire limits
are explicit and kernel scope limits are read back; placement and concurrency admission are
separate caller obligations. One runtime capability and the local user manager/cgroup2 path are
required. Declared valid argv/cwd/environment and descriptor semantics are retained; embedded NUL
is refused before fork. A failed manager connection stops and confirms the trusted child before
joining its readers. Startup, output and unconfirmed shutdown have closed error constructors.
The caller still independently observes its domain postcondition. This process result cannot
substitute for a registered runtime, resource-absence receipt or deployment qualification.
Kernel membership must survive reparenting, a new session and the initial leader's exit before
any slot is physically owned. PID/start-time snapshots diagnose observed processes but cannot
prove absence of a descendant that already left that observation graph. The owner binds its exact
kernel scope before effect admission and independently confirms terminal emptiness; startup,
cancellation, output settlement and cleanup share the original deadline. The adapter preserves
the declared environment, working directory, stdin/stdout/stderr and exit result, and cannot acquire
authority over an arbitrary caller-supplied PID or scope name.

During stop confirmation and alarm retirement, a transient observation/I/O refusal does not end
observation of the held group. Both use the same bounded observer: it retries that identity inside
the earlier of the original lease and caller end, returns a populated group immediately, and
retires its alarm only after a positive terminal observation. A refusal never supplies absence;
an expired or closed handle cannot become a new observation window. Callers preserve the owned-child refusal
before checking whether the returned command consumed the work deadline.

`Prodbox.Capacity.HostExecution` compiles topology-indexed resource plans against the observed
host plan's remaining budget. The serial plan funds parent, command and expiry helper through
one serial command lane. The transport plan additionally funds a concurrent persistent transport;
its two runtime-memory slots bind command plus helper first and transport second. Their exact
positive peaks, finite CPU/task bounds and combined host draw are checked together. The validated
runtime budget retains a fixed-size optional pair, rather than an arbitrary input peak list.
The outer memory ceiling funds the whole slice once, and the parent receives the remainder after
all child roles. The existing serial placement boundary accepts only the serial plan type; a
transport plan requires its own complete physical owner. Neither arithmetic value allocates a
runtime slot or grants an Authority operation permit, and unit repartitions establish no measured
production profile.

The private `HostOperationFamily` request binds controller, command, transport, timer, helper and
runtime-directory names to the closed controller kind and operation key. Registration and ordinary
cascade kinds use disjoint manager fields, slices and runtime directories, including their command
and transport scopes. The program's kind must match the intent and publisher before submission-record
publication or manager send. Publication namespaces, producer records and recovered never-sent owners
retain the same closed kind; both namespaces are reserved against raw-file submission. Input
retirement derives its namespace from that original kind and rejects another kind's payload paths.
The recovered submission record selects the same exact retirement field and kernel slice; historical
registration encodings retain their identity, and the bounded ordinary-kind wrapper cannot contain
another kind wrapper. This metadata grants no permission to borrow a registration request or its
original admission for ordinary work. Each kind's fixed slice is its physical slot; the original
absolute timer requires it while armed. Its no-op helper conflicts with and orders before the
keyed controller. Actual role scopes bind to and order after that controller, so controller loss
stops them and shutdown orders them before the controller/helper boundary. Direct helper-to-scope
references would retain terminal loaded scopes and prevent serial reuse. Controller mode/arguments
and RTS policy are closed over the calling program and explicit input paths. An intent admits one
submission. Its local claim uses `Prodbox.Subprocess.OneShotAttempt`: a direct atomic Bool swap
consumes that intent value before validation/send, and cancellation or a later refusal cannot
reopen it. No blocking waiter queue or update-selector closure belongs to the quiescent cell.
This is a local one-attempt fence, not durable operation retirement or an Authority grant.
The registered caller's shared counter budget forces its initial eight-field data record and
finishes each atomic update under an uninterruptible mask. Only the closed, total calculation over
validated `Word64`-bounded counters belongs there; no supplied callback, external blocking effect
or unbounded arithmetic may enter that section. Cancellation can consume a quota without running
its effect and cannot retain an unfinished update selector. Its quiescent field term is separate
from the one-shot claim, executing callers and complete resource/admission evidence.
Existing or unobservable field
observations refuse before mutation. The read-only inventory preserves absent, present without an
invocation, and unobservable states. Neither submission nor inventory grants a placement or
Authority capability. The caller must bind production dispatch, pinned inputs, kernel role
ownership, independent terminal evidence, alarm retirement and original-bound recovery before
exposing a supported route.

The scoped program selector holds no-follow executable, configuration, request and parent-directory
descriptors. Configuration/request inputs must be regular single-link files owned by the effective
user, mode `0400` or `0600`, beneath a private `0700` parent. The executing image must match its
opened executable identity. The closed manager command carries a versioned fingerprint of public
stat metadata, roles and paths. The controller checks that fingerprint before decoding input bytes;
it is not a content digest or authentication receipt. Payload bytes never enter the fingerprint.
Same-descriptor reads enforce a 1 MiB ceiling per serialized input and retain raw bytes without a
`Show` instance. Path rejection precedes normalization at 4,096 characters. Held/linked file and
parent identities, ownership, permissions, versions, scope lifetime and the original work end are
rechecked before submission and parent effects. Escaped or changed program capabilities refuse
before a family is submitted. These ceilings grant no decoded-state memory budget. Immutable launch
files stay distinct from the Tier-0 file the coordinator may publish.

Native submission, publication-birth and ordinary-scope records decode String fields through
`Prodbox.Config.SerialiseString`. The selected `serialise` instance uses text for ordinary Unicode
and generalized UTF8 bytes for Strings containing surrogates. Check every byte of the latter before
its unchecked SDK traversal; preserve the valid String domain and exact encoded bytes. The enclosing
record still owns its byte ceiling, semantic validation and canonical read-back. The guard supplies
no decoded-state or transient-memory budget, native ownership or admission capability.
`generalisedUtf8ScalarCount` validates the same byte grammar and observes its exact Char count
without constructing Text, String or Char values. A caller using that count before allocation must
bind the selected payload to its actual enclosing schema and retain the decoder's canonical and
semantic checks. The count itself supplies no complete memory bound or admission witness.

When request validation needs captured settings, the bounded canonical request envelope exposes
only untrusted root/scope coordinates after matching the supplied original key and window. The
loader validates settings from the held byte pair, then recompiles the complete request against
that settings value. Canonical settings re-encoding and returned-preparation checks prevent a
decoder or preparer from substituting another configuration or request. Coordinates, decoded
preparation and file leases do not grant a process owner; the observed original kernel parent and
its fresh manager/clock checks remain independent.

The controller argument renderer and parser share one closed nine-pair wire layout. Paths,
fingerprints, keys and canonical machine-width decimal clocks are checked before input acquisition.
The pinned loader opens that scoped owner before decoding the request and canonical settings,
then prepares fresh native resources under the original work end. The producer-facing facade also
compares the files with the exact encoded preparation before offering one family submission.
Its process callback consumes the existing observed kernel-parent lease and the declared command
and transport stream limits; file metadata or decoded preparation cannot grant physical placement.
Descriptor closure preserves the launch files. Their publication/lifetime owner retains them
through an unknown submission until independent family absence permits retirement; callback or
submission completion alone cannot authorize deletion. Production dispatch, explicit caller and
clock-domain binding, Authority credentials/admission and recovery compose these separate owners.

Ordinary launch compares the complete settings, request and compiled plan with the original
preparation and retains its original one-shot intent. Every send consumes the fixed publisher's
native submission permit. Historical recovery constructs only a metadata reference from the
checked native ordinary-kind submission record; it does not decode old settings, prepare another
intent or renew the original work window. A fresh read budget observes the exact field and causal
processing frontier. Independent physical/alarm retirement precedes exact submitted-payload
retirement. Never-sent recovery uses the native publication owner and original key without old
settings. Payload retirement retains the public one-shot and runtime-epoch fences for their
separate lifecycle owner.

The ordinary controller body accepts its administrator credential as an explicit in-memory
operand, distinct from persisted public settings and requests. Pinned input and actual original
process ownership precede credential shape and configured-backend-region validation and captured
caller preparation. The graph derives credential-retirement parameters only after the exact
authenticated original AWS-scope result supplies account and region; the fixed Provisioner endpoint,
captured image/Agent/context and original program IAM binding, lineage and deadline supply the rest.
The native operand uses an opaque anonymous-pipe owner bound to the original key and work window.
Only the existing published ordinary-family submission path accepts it; null input is the default.
The owner offers once, attempts delivery only after an actual manager reply, and closes the writer
on completion, failure or cancellation. Both producer and receiver enforce the 64-KiB frame bound;
the receiver rejects regular files, terminals and named FIFOs. The fixed controller verifies its
actual original process owner before reading and rechecks ownership after decoding. The private
credential frame binds its version, original key and public request digest, and rejects malformed,
trailing, substituted or noncanonical input. Credential bytes are neither persisted nor included in
public request digests. A pre-acquired operand does not establish its prompt origin: approved
credential acquisition, production dispatcher integration, complete program funding and independent
Authority admission remain separate capabilities.

The request requires an explicit existing operator/harness caller; decoding cannot select a
default or a service principal. Its native domain records the kernel boot ID, bus instance ID,
pinned manager unique name and UID, and manager PID/start ticks. These values remain metadata.
Preparation compares fresh observations under the original work end, and submission and physical
parent acquisition repeat the comparison on their exact opened manager connection. Closing reads
reject manager/process replacement during a snapshot. This comparison does not grant process
ownership, Authority admission or causal closure of an uncertain earlier submission. Historical
field reads remain read-only and cannot re-admit work in a new domain.

External caller-token acquisition has one closed service-account observation, self-TokenRequest
eligibility and token-request program. Both host interpreters use the existing caller tuple and
refusal classifiers. The operation interpreter consumes the opaque preparation's captured embedded
home kubeconfig and environment through its managed command lane; it checks the original
host/Authority bounds before and after every stage. It does not rediscover configuration or start
an independent subprocess owner. Early refusal cannot proceed to a later stage. The returned token
is data for Vault authentication and supplies no RPC signer, Authority permit or terminal cleanup
receipt. The caller's Vault/session/signing owner composes those separate capabilities.

The opaque prepared caller-authentication owner retains that exact preparation and captured home
context. Its explicit initial/registered signing source must match the captured registration
mode before token acquisition or login. The canonical cached Vault session logs in and refreshes
through the same held token program and existing caller tuple. Provider resolution and every
signature recheck physical ownership and the original host/Authority clocks; deadline projection
uses the original coordination deadline. The authenticated coordinator consumes only the
preparation retained in that opaque owner. A supplied registry snapshot/observer, caller token or
session supplies no Authority admission or physical placement grant. Registered selection still
requires its independent fresh native/registry checks. Cancellation propagates through the login
boundary; a closed parent refuses before another provider request.

Caller authentication metadata JSON responses are bounded before decoding. Kubernetes-auth login,
retained Authority epoch reads and Authority manifest public-key observations share the
existing 128-KiB native RPC response ceiling, declared by
`vaultControlPlaneResponseMaximumBytes`. Oversize and malformed replies remain structured
errors. The epoch reader selects the bounded metadata primitive explicitly; large retained
replay projections retain their separately funded read path. Response ceilings grant no
physical placement, complete-program resource budget or Authority admission.
The scoped native counterprogram and frozen/replacement reply evidence are preserved in
`test/qualification/HOST-CALLER-VAULT-RESPONSE-BOUNDS-2026-10-27.json`.

The Kubernetes namespace UID reader projects the first `metadata` and `uid` keys directly from
Aeson's validated token stream. It drains ignored values and validates trailing data before
returning a result; finding a UID never admits a malformed remainder. First-duplicate-key
selection matches the pinned value decoder. Ignored arrays/objects do not become retained value
trees. Nesting still uses lexer and continuation state, so this is not a constant-memory claim for
arbitrary depth. The full two-MiB SDK output domain is retained; complete decoder/native/GC and
ordinary-program admission remain separate resource obligations.

`httpRequestRawBounded` also bounds retained response headers independently of its body ceiling.
Each call admits at most 100 `103 Early Hints` blocks and 100 header fields across those blocks
and the final response. The singleton manager explicitly retains the pinned parser's 4,096-byte
line and 100-field per-block settings. Early-hint callbacks debit before the next recursive parse;
final fields debit before body collection. Header-limit refusals remain distinct from body-limit
and transport failures through the control-plane client and payload-free TLS/Target diagnostics.
Cancellation escapes the two typed exception handlers. Ordinary `100 Continue` responses do not
retain early hints and remain under the original response deadline. These protocol limits do not
prove complete HTTP memory funding: the parser's current block, status/parser state, body copies,
decoded values and kernel state still need their own bounds. The native old/new recording lives in
`test/qualification/HTTP-RESPONSE-AGGREGATE-HEADERS-2026-10-29.json`.

Bounded response bodies use a demand-grown buffer rather than retaining every network fragment.
`Prodbox.Http.BodyBufferBudget` carries the original limit, used prefix and capacity in an opaque
cursor shared by runtime allocation and pure planning. Each accepted append checks remaining
space before machine-width conversion or pointer arithmetic. Capacity grows geometrically up to
the response ceiling, and the returned bytes expose only the filled prefix, without a final
concatenation copy. For ceiling `R`, reachable owned payload capacity during a resize is at most
`2*R`, and cumulative owned payload allocation is at most `3*R`, independent of fragmentation.
These exclude incoming chunks/CString copies, cursor/ForeignPtr overhead, parser/header/status
state, decoded representations, GC and native/kernel costs. Exact overrun counts use `Natural`.
The preserved native counterexample and replacement recording live in
`test/qualification/HTTP-BODY-FRAGMENTATION-2026-10-30.json`.

`Prodbox.Capacity.RegisteredCallerTraffic` describes one captured registered caller. For `n`
ordinary signed frames, including ordinary peer refreshes, it charges `2 + 2*n` private registry
observations, `5*n + 4` signed frames and `7*n + 6` protocol HTTP requests. With `s` ordinary
channel constructions it charges `1 + s` scopes and `3*n + 3 + s` forwards; repeated construction
of the same role still counts. Native Vault origin/public/signature costs remain separate from
that protocol traffic. Epoch observations cost at most one primitive per ordinary frame, and the
lazy manifest observation has one result slot claimed before I/O, including cancellation.
The original remaining window bounds serialized readiness retries at one per 250-ms delay, in
addition to each forward's initial probe. Each allowed login owns one login HTTP request and three
managed token stages; one configuration capture precedes construction. Token-consuming Vault
primitives allow their one explicit 403 retry, while HTTP contributes no hidden replay.
The native Haskell HTTP total excludes traffic inside subprocesses, whose closed command and
transport programs retain their own bounds.

The checked cost rejects empty window/login allowances and machine-width overflow. Its shared
`Prodbox.ControlPlane.RegisteredCallerBudget` owner validates canonical per-attempt traffic and
debits before effects; failure and cancellation never refund uncertain nonce attempts. These are
planning/enforcement values. The closed program still derives its actual frame/scope counts and
funds all bodies, memory and replay, and obtains physical and Authority admission separately.
Counts for an aggregate qualification containing other actors cannot substitute for this caller's
schedule. Current integration and closure ownership remain in Sprint `6.5`.

The Provider boundary accepts the program's existing Authority transport through
`productionTeardownProviderBoundaryWithTransport`, preserving the stable submission key,
cleanup owner and shared executed/refused/unresolved classification. Creation observation uses
`readProviderCreationBindingWithTransport` with the original confirmed scope operation and cleanup
scope. It rechecks the selected registered key, coordinate, registry revision, foundation, AWS
scope and surface before independently reading creation provenance, then checks the creating
operation and Provider revision. These library helpers create no settings, scope identity, clock
window or authentication owner. Their composition into the complete admitted ordinary program
retains separate resource, replay and lifecycle obligations.

`withEksClientAuthProjectionForTeardownExecutionWithTransport` borrows that Authority
transport for the sealed node/attempt submission key and exact cleanup operation owner. It uses
the existing encrypted projection decoder and binding/expiry checks; an unknown result requires
durable attempt recovery before another ephemeral destination is issued.
The `EphemeralKubectl` constructors ending in `InOperation` consume the observed operation
parent and captured tool/environment; the home constructor also consumes its already validated
embedded projection. They create private files under the original runtime directory, close command
admission and join uses before removing those files. Escaped clients refuse. Each invocation borrows
the original single command lane and clips its SDK time/stream ceilings to the existing parent's
allowances. This cannot enlarge the parent plan, create another lane or refresh its absolute window.
Complete ordinary-program admission and production body/resource funding remain separate.

Host storage admission distinguishes the node's ephemeral filesystem, the retained volume and the
effective user's fixed `/run/user/<UID>` runtime filesystem. The runtime observation uses an owned,
non-symlink directory and a held descriptor under the original operation work end. Stable device,
inode and filesystem geometry bind the observation; current available bytes may change and must be
rechecked before borrowing inputs or processes. The lower of two availability reads is conservative
for that observation, but grants no reservation against concurrent writers. Unknown, expired,
replaced or insufficient storage refuses; node capacity cannot stand in for runtime capacity.
SDK RSS and client-only commands likewise establish neither a child cgroup peak bound nor complete
controller funding; shared file-cache attribution and actual forwarding work remain separate inputs.

`productionCloudRuntimeInOperation` assembles the cloud dispatcher from
`OperationCloudRuntimeInputs`: the observed process owner, original confirmed Provider scope
operation, captured embedded home projection, tool/environment and bounded drain lease. Provider
dispatch, generation selection, provenance and durable readers use the supplied Authority
transport. The EKS selection/attempt and home/AWS DNS factories use the same command owner. These
inputs provide no host caller or repository root for rebuilding authentication. Both production
compositions share the private dispatcher assembly and the adapters' projection/error and mutation
logic. DNS owner commands also append the SDK's named per-request timeout; the whole-command
window remains independently clipped to the original operation. Existing public routing stays
with its current composition until the complete ordinary program is admitted and qualified.

The operation Authority channel retains that native forward and exposes no raw client or endpoint
setter. Counted borrows cover provider resolution, native signatures, strict hint decoding and HTTP.
Closing marks the scope before joining admitted work under its original native work end; escaped
calls refuse before another provider or network effect. Nested validation may itself use this
channel: the lifetime counter holds no mutex across effects, and a separate mutex serializes only
HTTP. Successful borrows repeat native transport ownership before/after their effects and clip their timeouts
to that same absolute work end. Cancellation propagates through bounded URL parsing. Ordinary
transport keeps the 64-KiB response ceiling; the registry-purpose client selects the existing
139,520-byte purpose bound on that same channel. These lifetime checks grant neither Authority admission nor resource/
replay capacity. Native old/replacement escape, join, nesting, exception and cancellation evidence
is recorded in `test/qualification/HOST-AUTHORITY-CHANNEL-LIFETIME-2026-10-27.json`.

`ControlPlane.OperationUse` shares the counted owner with exact parent/transport observers.
`ControlPlane.HomeEndpoint` owns the five compiled home-service coordinates and their loopback
startup mappings. The owned Authority channel first observes an exact newline-terminated mapping
on its own child stdout, then performs HTTP readiness. Missing, partial, foreign or unavailable
acknowledgements grant no readiness. Pending startup uses only the original work end.
`Subprocess.StartupLine` retains bounded matcher state and publishes only semantic status from the
existing output reader. Its fixed 4-KiB metadata allowance must fit the transport half of the
existing other-heap reserve before launch. No extra reader buffer or deadline is allocated.
Historical controller request data remains decodable; fresh effect preparation checks the added
funding requirement. The original/replacement native startup record is
`test/qualification/HOST-OWNED-FORWARD-STARTUP-2026-10-27.json`; it grants no Authority admission
or deployment qualification.

Registered signing selects active entries for the actual native scope/Vault/key origin and the
highest matching logical generation. The runtime and explicitly caller-bound interpreters share
that selector. Selection metadata grants no capability: fresh native origin/public-version and
current registry checks precede capability construction and surround every native signature.
The explicit native signing version stays distinct from the logical wire generation. A signing
capability supplies no operation admission or physical ownership receipt.

The private registered bootstrap program in `RpcAdmissionBirthBootstrap.hs` accepts native-only
origin/public/signing effects and returns registry metadata. Its temporary signing capability is
constructed and consumed entirely inside the fixed peer-context refresh and registry read; no
caller receives that capability or a callback that can use it. Hint decoding alone cannot attest
the key. Fresh native checks surround each exact-version signature, and the complete authenticated
registry must still select that same highest active binding and match the independently captured
descriptor pin. Logical generation remains separate from native key version. The original Authority
deadline spans the program, and `LocalClient.hs` additionally encloses it in the original monotonic
operation-channel borrow. Neither clock is renewed. The native-only algebra is shared with ordinary
checked signing and contains no registry read. The prepared caller owns the separate session and
checked-signer composition; metadata observation supplies no physical or Authority admission.

`coordinatePreparedRpcBirthCallerOnOperation` is the total prepared-caller entrypoint. It privately
owns one operation channel and one cached caller Vault session, selects the captured registration
mode, constructs the ordinary checked signer, and coordinates on that held transport. Registered
signer validation reads fresh metadata through the private bootstrap program without recursively
using the signer it validates. An unavailable observation is a distinct registry refusal. The held
execution arm retains the managed command lane and captured kubeconfig/environment; it opens no
second forward and cannot select the serial host interpreter. Only the coordination result leaves
the total owner. Session refresh uses the original token program and clocks. One opaque
`RpcBirthNonceBudget` shares the closed initial/registered allowance across ordinary and private
signing. Its atomic debit precedes nonce generation; cancellation, source failure and copied owners
cannot refund or duplicate that allowance. `RpcBirthTraffic` derives the 12/44 signed-request
ceilings, including peer refresh and the registered reader's checks around ordinary signatures.
This per-invocation bound supplies no physical or Authority admission and does not establish the
complete qualification/recovery invocation schedule. Additional metadata and replay traffic still
requires production capacity admission before deployment qualification.

`RpcAdmissionBirthWire` owns the unchanged request-family prefixes and response ceilings without
importing a client or effect interpreter. The authenticated Authority producer applies the shared
64-KiB command/descriptor and 139,520-byte registry bounds before delivery and replay completion.
An oversized response leaves its reservation unresolved; it cannot fabricate a smaller successful
observation. The classifier grants no authentication or read policy, and unrelated migration bodies
retain their existing response policy.

The registered `internal-rpc-birth-controller` leaf consumes the shared closed nine-pair argument
model. Its ordinary argv validator and parser binding both validate that model; traversal components
and noncanonical clocks refuse. The command model depends only on low-level metadata, avoiding a
cycle through the runtime/chart interpreter. `RpcAdmissionBirthController.hs` keeps pinned inputs
and the observed process owner around preparation and the total caller. Typed App dispatch skips
repository discovery and schema materialization. Publication resolves through the Repo-owned naming
rule from the already-held executable path, independently of the working directory or retained
storage root. None of these metadata arguments alone grants an operation owner or Authority permit.

The registry observation request uses the runtime's same fenced projection and the bounded
birth read algebra: clock, primary and marker reads only. Its exact Operator/Harness request is
separate from descriptor and mutation commands. The canonical response binds public registry
history to the original complete home seed and birth descriptor; it contains no inner admission
payload or credential. The client bounds providers, peer refresh, signing, HTTP and strict decode
by one original deadline. Its distinct response bound covers the registry's existing byte ceiling;
ordinary metadata limits remain unchanged. A host consumer must separately compare the descriptor
with its independently captured pin and retain native source/membership checks around signing.
The response is currently unsigned: its original-seed digest does not authenticate later key
registrations or retirements. A local substitution control is recorded in
[Sprint 6.5 Resume Here](../../DEVELOPMENT_PLAN/README.md#resume-here). Returned metadata supplies
no independently authenticated current registry, capability, physical origin proof, renewed work
window or retirement receipt. Serialized byte limits alone supply no heap or host admission proof.

Registered external-caller bootstrap has a distinct untrusted own-binding hint. Only its exact
versioned query on the migration route bypasses ordinary frame authentication; every other body
and route retains the installed authenticated handler. The query binds configured Authority scope
and exact native origin, including canonical Operator/Harness key reference. Service and worker
principals refuse. Strict canonical codecs bound the query at 20 KiB and the one-binding response
at 21 KiB, including the existing maximum Unicode scope fields. The read-only birth algebra confirms
the primary revision around its marker, requires the independently configured registered pin and
selects from the same retained authentication projection. Legacy, missing, corrupt and unobservable
provenance refuse; the program cannot seed or mutate. A fixed server-owned two-second window covers
retained reads and strict response encoding. This public hint is data only. The bootstrap consumer
must independently attest its native origin/public version and obtain an authenticated current
registry before constructing an ordinary checked signer. The current response verifies the pinned
original seed and the caller's own binding, but does not authenticate the full later registry.
Native matching alone cannot attest an untrusted logical generation or current registration.

The native input producer traverses the compiled `/run/user/<uid>` root without following
symlinks, requiring trusted ancestors and the effective user's private runtime directory. It
creates an exclusive operation-key directory and owner-read-only single-link files, bounds and
synchronizes each write, and compares exact bytes and held/linked versions before lending the
paths to the launch facade. Environment variables cannot select this root. An existing operation
directory refuses without overwriting it. Descriptors close on return, exception and cancellation;
complete or partial input files remain for their separate retirement/recovery owner. No callback,
submission acknowledgement or file-publication result supplies family-absence evidence.

The native family publisher records its exact daemon-assigned sender, confirmed against the
current process UID/PID, before sending `StartTransientUnit`. The exclusive owner-read-only
sidecar under the held request parent binds the original key, five clocks, manager/boot/bus domain
and complete public input stat metadata. It contains no configuration/request payload. File and
directory synchronization, same-descriptor read-back and closing input/domain checks precede the
call. An existing or partial record refuses without overwrite; release, error and cancellation
preserve it. Its canonical codec and descriptor reader enforce a separate 64-KiB ceiling.
A fresh historical read can outlive the original work window and executable version, but returns
data only; exact key/request-path and controller window/domain matching do not re-admit work.
Exclusive creation fences competing attempts at that same published record path. Schema two adds
the exact provider policy/build reference and router/namespace provenance before sending. The strict
reader preserves schema-one bytes as unqualified data; it cannot upgrade historical handler evidence.

The package-private `SystemdProvider` owner recognizes the exact protocol images in
`SystemdProviderProfile`. Root-owned directory traversal, same-descriptor hashing and held/linked
file versions bind those images to the manager/router executable mappings. Native observations
require nonroot matching real/effective/saved/filesystem UIDs, empty permitted/effective/ambient
capabilities, one mount namespace, unconfined AppArmor and absent SELinuxfs enforcement. Inheritable
capabilities do not grant active authorization and are not an input to the reviewed same-UID
privilege decision. Original and shortened deadlines cover every observation. Release invalidates
the opaque owner before closing image descriptors. Native bus closure similarly invalidates every
borrowed view before releasing its pointer/library; an escaped view cannot call freed native code.

Historical recovery freshly qualifies the same provider binding and original manager domain,
positively observes the original sender absent, reads the exact six-role field on the pinned
manager, and repeats provider/domain and sender checks. Only then does it return an opaque witness
bound to that exact submission record. Present roles are allowed: the witness certifies completion
of the reviewed synchronous method handler, while queued jobs and physical state remain separate.
Unobservable fields, live senders, foreign bindings/domains and unqualified history refuse. The
controller facade also matches the original request window/domain before this read. Independent
terminal kernel, alarm and immutable-file evidence is still required for retirement or recovery.

The package-private `HostOperationRetirement` owner borrows that same qualified provider and
processing witness. It holds anchored cgroup-parent and private runtime-root descriptors, matches
the pinned manager's `ControlGroup` to the shared physical-placement path, verifies the cgroup2
mount, and independently observes the exact family path and keyed workspace absent. Its bounded
manager-startup metadata read confirms that the cached runtime prefix is the expected private
root. It exports, logs and hashes no environment bytes and obtains no configuration or
authentication from that observation. The reviewed manager refuses unit garbage collection while
jobs or queued cgroup settlement remain, coupling its terminal field to the completed method.

Before lending the owner and on every verification, repeated exact-role, provider/domain/sender
and anchored physical checks consume the same fresh read deadline; unobservable roles take
precedence over presence. Original effect clocks remain unchanged, including historical reads after
their outer end. The opaque owner matches the complete original submission, and release or
cancellation invalidates escaped borrows before anchors close. The controller facade first matches
the original request key/window/domain and lends only this scoped observation. Neither interface
stops processes, unlinks inputs, grants Authority admission or serializes a retirement grant.
Immutable-file removal, partial progress and crash recovery require their separate exact-file owner.

`HostControllerInputRetirement` consumes a scoped borrow of that exact-record physical owner for
the entire fixed-publisher payload transaction. Native/provider/anchor handles remain live until
bounded borrows finish, including cancellation. It opens only the canonical private runtime
namespace, takes a nonblocking directory lock across threads/processes and matches original public
file/parent versions without reading configuration/request contents or reopening the historical
executable. An anonymous file becomes a complete named preparation journal only after file sync;
directory sync precedes payload mutation, including on resume after a lost or failed sync reply.
Exclusive quarantine renames, exact version checks, unlink and synchronized absence read-back
reconcile interrupted progress. A terminal journal permits repeated read-back but never deletion
of a recreated payload. Foreign, changed, missing-before-preparation or unobservable objects refuse.

The original submission and bounded public preparation/terminal journals remain as explicit
one-shot metadata fences in the operation directory until its runtime epoch is retired. The
payload receipt proves neither directory absence nor Authority admission. The controller facade
first matches historical key/window/domain and creates a fresh bounded physical owner before this
closed program; it cannot renew original work. Unqualified-history and changed-epoch dispositions
retain their separate recovery ownership. This serializes supported
writers and checks observed identities; it is not a kernel inode-conditional unlink primitive
against arbitrary same-user filesystem mutation. Native failure/crash and constant-envelope
counterexample evidence is indexed in
`test/qualification/HOST-CONTROLLER-INPUT-RETIREMENT-2026-10-27.json`.

The publisher's opaque live owner seals a one-shot submission gate and joins the entire bounded
submission before releasing input handles. The family validates the exact owner, key, original
work deadline and file versions and latches possible send before entering native IPC. Lost replies,
failure and cancellation cannot clear that latch. An unmarked raw-file send refuses the reserved
publisher namespace before record creation. A distinct scoped never-sent owner exists only after
the complete submission gate is sealed; missing or corrupt submission history supplies no grant.

`withPublishedRpcBirthControllerLaunchRetiringUnsent` gives that live owner to the same closed
journal program under a separate cleanup deadline. Its result distinguishes retired, unresolved
and possibly submitted inputs; it preserves the original callback exception or cancellation after
eligible closing work. Partial publication retains exclusively created file descriptors through
closing, admitting only unchanged owned files and positively absent unowned slots. Unsafe, changed
or unconfirmed ownership refuses deletion. Prefix publication failure remains the primary error
even after eligible cleanup. The ordinary publisher wrapper retains files on release.

The never-sent metadata is distinct from submitted-source metadata and never serializes a cleanup
capability. Preparation/terminal fences remain after payload retirement. Changed epochs and fence
retirement require their separate evidence.
Native lifetime, partial publication, syscall-error/recovery, raw re-entry refusal and submitted
regression evidence is indexed in
`test/qualification/HOST-CONTROLLER-LAUNCH-SEAL-2026-10-27.json`.

Publication prepares and synchronizes both payloads in anonymous held files. Before either fixed
payload link, it synchronizes a canonical version-two birth manifest and its directory; the new
operation directory is also synchronized through its retained parent. The manifest binds the exact
key, original work end, parent identity, both anonymous payload versions and its own original inode.
Its exclusive native file lock is acquired before naming and held through the entire creator scope,
including sealed closing work and borrow release. It leaves the separate directory lock available
to submitted cleanup. A copied manifest cannot stand in for the original locked inode.

The possible-send latch is set before publishing a one-shot synchronized marker, and native IPC
requires successful marker read-back. Any present or unobservable marker blocks cold never-sent
recovery. A failed pre-link marker publication never reaches IPC: after creator release, a fresh
native fence and positive marker absence may independently establish never-sent. Neither an uncertain
native call nor missing/corrupt submission history supplies that disposition.

`recoverNeverSentRpcBirthControllerInputs` matches the original request key/work end and borrows a
fresh native owner for the same immutable birth inode. It checks exact namespace and canonical
metadata before lending any cleanup capability. The shared closed transaction reconciles zero, one
or two linked planned payloads, including interruption before its preparation journal. The known
anonymous-link and quarantine transitions may change ctime; every other recorded field, including
mtime and the single final link, remains mandatory. Live known original versions retain their
stricter checks. Cleanup reads no payload contents and reopens no historical executable.

The recovery owner clips nested callers to its original fresh read bound and refuses expired or
escaped borrows. Its immutable metadata remains data alone. Pre-birth failure names no payload;
eligible live closing records separate unlinked-source metadata with its original parent identity.
Absence of a birth record grants no cold cleanup or namespace retirement. All payload receipts leave
the birth, possible-send, submission and preparation/terminal metadata applicable to that source as
one-shot fences; empty pre-birth namespaces and their epoch retirement retain separate ownership.
Ordinary publication errors, callback exceptions and cancellation remain primary after eligible
closing attempts, including when that closing attempt also throws. Native crash, syscall-error,
facade and frozen/replacement counterexample evidence is indexed in
`test/qualification/HOST-CONTROLLER-COLD-PUBLICATION-2026-10-27.json`.

The canonical six-role manager field has a separate key-only selector. Read-only controller
observation can consume decoded historical request data under a fresh read deadline without
constructing an effect intent, preparing resources or renewing the old work window. Role names
remain shared with submission. Per-role observations retain absent, present and unobservable
states; aggregate unobservable results take precedence over presence and absence. The shared
slice does not prove a keyed controller or timer present. Manager inventory grants no kernel or
Authority receipt, file retirement, or closure of a possibly queued/unknown admission; those
owners require their independent terminal and causal evidence.

The bounded exact-unique-name `NameHasOwner` read returns present/absent data or its structured
transport/decode error. It carries no expected-domain, provider-qualification, processing-frontier
or retirement grant. A consumer must retain those independent checks; a fresh read never renews
the original operation. The test-only same-process Unix-bus relay preserves real daemon UID/PID
while holding a complete launch frame or its successful reply. Positive effect schedules retain
the sender until the manager reply, then close it; the distinct blind-close schedule does not
wait for a reply and never promotes missing observations into a No-Go or held-kernel receipt.
The relay bounds authentication lines, binary frames and every wait by its original fixture end,
decodes no message body, and releases its own socket on normal, exceptional and cancelled exits.

Before an operation admits a child, its controller observes host capacity through bounded local
reads under the original work end. The native adapter rejects the test-capacity override, observes
CPU affinity and procfs memory, and reads filesystem totals from held no-follow directory
descriptors. Closing identity/geometry and expiry checks precede its result. No `nproc`/`df` child
or serialized observation substitutes for these reads. This observation is data; canonical resource
compilation, physical placement and Authority admission still grant their separate capabilities.

The versioned controller settings envelope carries only the canonical configuration and deployment
context as an import-free binary value. Its codec bounds serialized input and checks the producer's
closed data shape before allocating a general expression. The checker derives its schema from the
typed encoder; recursion follows that trusted schema and rejects untrusted expression nesting.
It preserves canonical numeric, text, list, optional, record and union values. Unknown schemas,
plaintext references, foreign scope and unsafe roots refuse before canonical settings validation.
Typed extraction followed by exact canonical re-encoding rejects extra fields and legacy shape
adaptations without resolving imports or normalizing the supplied expression. The encoded owner
has no `Show` instance; payload bytes never enter hashes or diagnostics. This settings value grants
no operation/program/window binding, resource admission, Authority permit or dispatcher route.

The separate closed request carries the home-registration program, canonical scope/generation/key,
Authority deadline, all five original host clocks, repository/context and explicit host/runtime/
transport/helper/stream declarations. Typed canonical decoding compares the independently supplied
launch key/window; settings context and resolved storage root must match before preparation.
Runtime memory uses the shared capacity compiler with the explicit host envelope. Stream buffers
and reader grace use the same heap/original-window checker as the physical subprocess owner.
Preparation re-observes native host capacity before compiling the settings allocation and extra
host draw, then rechecks the original Authority/host bound. Its opaque result retains the exact
request, settings and operation intent. This result grants neither physical placement nor Authority
admission; pinned input loading and the closed production dispatcher consume those separate owners.
Request preparation and rollout share one clock adapter: monotonic reads bracket the UTC read,
and the host's original outer end is compared from the earlier sample against the UTC reading's
microsecond upper edge. Clock-read/preemption time and quantization cannot enlarge the admitted
Authority remainder. The later sample bounds only remaining work; expiry, reversed samples,
invalid windows and unsafe machine-width conversions refuse without renewing any end.

RPC-birth operation preparation captures the home kubeconfig once through the admitted command
lane. One Docker read selects only image ID and repository digests; the canonical machine tag and
exact repository digest rules remain shared with ordinary chart planning. The API Endpoints read
uses that held home credential. Both observations feed the canonical opaque chart factory, and the
result retains the exact operation, request, chart and embedded configuration through coordination.
Preparation and reuse recheck the original window and parent lease; tools retain private state in
the managed runtime directory. Missing or ambiguous image identity and invalid API coordinates
refuse before registration. This capability grants no Authority permit or production dispatch.

Its private parent-only lease retains the controller's self PIDFD and invocation, references the
four declared manager objects, and anchors the slice, controller and keyed runtime directory.
Before effects it verifies exact manager/kernel limits, RTS heap, process membership, closed
controller command and original timer/helper declarations. Child absence, declared-not-found
placeholders and unknown observations remain separate. Closing invalidates escaped leases.
An existing empty `cgroup.procs` can report read EOF; only that membership read maps EOF to an
empty set. Open failures and other read errors remain refusals, and no membership read proves
cgroup absence. I/O refusals preserve their typed stage, error class and optional errno without
paths. This lease grants no child/transport slot or Authority permit.

Separate command and transport borrows reserve the two indexed process lanes. One borrow admits
one PIDFD-based create attempt; a failed or uncertain admission retains an unsettled role. The
parent checks its exact direct-process set while the trusted child waits before exec. Admission
retains the scope invocation, anchored cgroup and original limits; before Go the parent, both live
roles and exact shutdown dependencies are checked again. A role becomes reusable only after
positive held-kernel terminal evidence, reference release and exact absent/not-found manager
observation. A retained loaded/inactive invocation is not absence. Closing invalidates escaped
borrows and joins both lanes. These role boundaries grant no authenticated operation permit;
dispatch, input ownership, caller admission and original-bound recovery remain separate obligations.

The operation subprocess supervisor composes those borrows with the existing trusted fork,
Go/exec handshake, bounded output readers and shared group/leader stop routine. Each role receives
half the runtime plan's other-heap reserve for working output buffers and their bounded trimmed
copies; a fixed allocation prevents fragmentation from retaining a list of tiny chunks. The
controller plan dedicates that reserve to these buffers and fixed startup protocol state. Child
environments are explicit, and
command results retain raw bytes without an automatic `Show` instance. Retained results consume
the caller's bounded application-state budget. Commands may tighten work
but never renew the original window. Transport callbacks race exit, stream refusal and original
work expiry; escaped leases refuse. Callback failures attempt bounded cleanup and normal role
settlement. Cancellation and non-I/O exceptions are rethrown afterward; ordinary I/O failures
return structured refusals. Role cleanup retains the operation-wide alarm; the
standalone/serial runner keeps its own exact alarm-retirement tail. These process APIs do not
provide authenticated network readiness, production dispatch/input pins or domain-operation admission.

`withHostSubprocessPlacement` observes an already managed controller's own PIDFD, invocation,
finite RTS heap and original shutdown window. It retains read-only parent/slice descriptors and
checks exact manager/kernel limits and membership. `captureHostSubprocess` borrows its serial
slot, checks the caller-keyed scope/timer/helper field before fork, and places child and helper in
that held aggregate slice. Before Go it rechecks the parent, held child and dormant helper's
closed no-op command and limits. All calls retain the same recoverable family key and five
absolute work, hard-stop, confirmation, settlement and outer ends; an uncertain request cannot
renew them. A present or unobservable family refuses before another fork. Closing invalidates
escaped borrows. The enclosing interpreter still owns authenticated operation admission,
the closed managed-controller launcher and independent domain/runtime readback.

Each controller service owns its private runtime directory with mode `0700` and preservation
disabled: `prodbox-rpc-birth` for serial placement and the execution-keyed directory for an
operation. Placement admission holds a no-follow directory descriptor,
checks effective-user ownership and private permissions, and requires the linked path to retain
that exact device/inode before child admission and effects. Its workspace is distinct from the
held cgroup descriptors. Chart bytes, flattened embedded-credential home kubeconfig, values and
tool home/cache directories live beneath it, so controller death does not depend on Haskell
finalizers to remove them. The serial runner also removes individual working directories on normal
completion. Operation workspaces remain under the manager-owned root until controller retirement,
including when an uncertain child-cleanup result might leave a reader using the staged file.

`Prodbox.ControlPlane.RpcAdmissionBirthRollout` binds that host placement's key to the authenticated
Authority scope, generation and operation key. It captures and validates the explicit loopback
home kubeconfig before Prepare, then interprets only the retained chart revision under the
original host/Authority bounds. It refuses pending or unobservable releases and terminal retained
revisions; it never uninstalls the retained Authority to obtain a clean release. Exact journal
claim/volume observations precede and follow apply. A returned Helm failure remains a failure
even when the closing release status is deployed. Only the coordinator's independent authenticated
running-descriptor observation can admit Complete.

The operation-backed rollout derives its key, original clocks and workspace from the admitted
operation capability. `withOperationLifecycleAuthorityAuthenticatedTransport` shares the same opaque
embedded home projection with the command role and holds the separate transport role throughout
coordination. The fixed mapping is loopback-only to the retained home Authority service; tool
home/cache paths are private and ambient credential selectors are scrubbed. Readiness responses
are bounded to 4,096 bytes, and every probe and retry consumes the original work window. Birth and
peer metadata responses are bounded at the HTTP read boundary by the existing 64 KiB metadata
ceiling. Process and readiness observations do not grant a serving-descriptor or domain-operation
receipt. The closed dispatcher and pinned inputs consume this ownership composition. Production
resource/replay admission and recovery remain required before operational activation.

Embedded home-credential validation, closed projection and private file creation belong to
`Prodbox.Lifecycle.Teardown.EphemeralKubectl`, alongside the existing projected bearer client.
The rollout retains its opaque `EmbeddedHomeKubeconfig`; it cannot substitute unvalidated bytes
at the write boundary. The owner creates the kubeconfig exclusively without following a pre-placed
path, uses owner-only permissions and syncs/read-backs its bytes before returning the path. The
rollout also reuses that owner's ambient credential-environment scrub and places tool caches in
the managed runtime directory. Credential-field policy and the private credential writer are
not restated at the caller.

`Prodbox.Subprocess.SystemdBus` is the package-private local manager transport. Its explicit,
owner-checked Unix socket does not use ambient bus-address discovery. Authentication and
asynchronous replies consume the original monotonic deadline; bounded native polls allow
cancellation, and brackets release messages, reply slots, callbacks and connections. Manager
methods form a closed set and failures carry closed causes rather than raw backend text. A bus
action's `IOException` is classified separately from an I/O exception outside the action; that
boundary classification does not identify whether a nested operation caused the exception. A bus
connection is transport alone: the process owner separately attests the manager, exact unit,
kernel descriptors and admitted resource plan. A late continuation cannot produce success, but
the transport does not impose a hard runtime bound on arbitrary caller IO.

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

`runStreaming` preserves process-group Ctrl-C as cancellation and waits for the delegated child
exit in the calling command thread. Do not move that wait behind a private reaper and an
exit-observation `TMVar`: `process` delivers delegated `UserInterrupt` synchronously to the thread
calling `waitForProcess`, so a private waiter can terminate before publishing the observation and
strand its caller. Captured and bounded paths, which do not delegate Ctrl-C, retain their
`typed-process` ownership.

A bounded framed exchange that has more than one transport step reports transport failure through
an exhaustive stage ADT, not one undifferentiated error string. The stage may distinguish only
value-free interpreter boundaries such as limits validation, input admission, process start,
framed writes/reads, final-frame read, stderr drain, trailing-stdout validation, process-exit wait,
and wall-clock timeout. Domain projection may map those
constructors to fixed public tokens, but it must not expose the underlying exception, child output,
payload, or frame bytes. Adding stage evidence is diagnostic only: it does not authorize retrying
an ambiguous exchange or changing its deadline, cleanup, or protocol semantics.

The same rule applies before a subprocess exchange: retained session allocation/preparation maps
its structured interpreter error to an exhaustive value-free domain cause before the coordinator
can log or render it. Do not carry bounded arbitrary `Text` merely because its length is limited;
bounded private detail is still private detail. When a retained preparation stage contains another
closed error algebra—such as accessor-audit preclean—the projection preserves that nested stage as
fixed constructors/tokens rather than collapsing it or exporting its provider detail.

Why this matters:

- Subprocess sequences become deterministic golden-test targets.
- `--dry-run` is trivial: render and print the planned subprocesses, exit 0.
- The type system rules out "forgot to set cwd" or "leaked stale env" bugs at
  the call site.
- Subprocesses compose as plain data — a `[Subprocess]` is a first-class plan
  (see [Plan / Apply](./pure_fp_standards.md#8-plan--apply)).

**Forbidden patterns:**

- Calling `callProcess`, `readCreateProcess`, `System.Process` constructors, or
  `typed-process` smart constructors directly from a command runner. The two
  interpreter functions above are the only IO boundary for subprocess
  execution.
- Resolving paths, expanding env vars, or branching on the host inside the
  interpreter. The builder is total; the interpreter executes what it's given.
- Returning subprocess output through `IORef`, `MVar`, or other shared mutable
  state instead of a typed `ProcessOutput` or owned `OperationProcessOutput` result.
- Reading configuration from environment variables. `lookupEnv`, `getEnv`, and
  `getEnvironment` from `System.Environment` are linted out of supported config-
  loading paths (host `Settings.hs`, daemon `Gateway/Settings.hs`, workload
  entrypoint). Every runtime configuration value lives in the Dhall file at
  `--config`. The k8s Pod environment may still carry runtime metadata (Pod
  name, namespace) that the binary does not read; the lint rule is scoped to
  the config-loading paths. See
  [config_doctrine.md](./config_doctrine.md).

The owned Credential Provisioner consumes captured `OperationProcessOutput` bytes directly for
JSON and worker-receipt decoding through `runOperationHomeKubectlBytesWithInput`. Its legacy
`ProcessOutput` entry retains the String interface. Both entries share the same original checked
client/use/command owner; selecting the byte result grants no additional process or deadline.
Stderr-only absence decisions use the shared probe vocabulary through `reportsAbsenceBytes`.

### Subprocess environments must be PATH-preserving

`Subprocess.subprocessEnvironment` is `Maybe [(String, String)]`. Its explicit list **replaces**
the child environment wholesale rather than merging with the parent's. So a `Just []`
(or any list that simply omits `PATH`/`HOME`) hands the child process an environment with *no*
`PATH`: the vendor CLI cannot resolve its own helper binaries, find a credentials file under
`$HOME`, or locate anything off the search path.

Any subprocess that needs auth or path-sensitive state must therefore build its environment by
*overlaying* the desired keys onto the inherited parent environment, never by handing the child a
from-scratch list. For the pre-cutover AWS CLI adapters, this is the job of the one canonical
`awsCliSubprocessEnvironment :: Credentials -> IO [(String, String)]` helper: read the parent
environment with `getEnvironment`, strip ambient AWS auth keys, then overlay only the exact
credentials supplied to the adapter. Those adapters are compatibility code, not authority to read
repo-root/ambient credentials or introduce a host-direct AWS mutation path. In the target runtime,
only the retained-home Provider Worker or a permit-indexed runner may supply an admitted Vault
generation to such an adapter.

The operation-owned `NativeSubprocess` form consumes an explicit `ProcessEnvironment` instead of
the string field. Capture retains native entry bytes; authored overlays use filesystem encoding.
It preserves inherited entry order, duplicate/empty keys and GHC's no-separator behavior without
retaining linked character lists for values or re-encoding them for each child. The data has no
`Show` or serialized representation and grants no process slot, window or Authority capability.
Both invocation forms pass through the same original command/transport owner, input/stream limits,
Go/exec gate and joined cleanup. Encoded input usage is distinct from a complete heap/native bound.
Its owner supplies a separate quiescent data projection over the actual list, pairs, metadata
scalars and established byte-buffer origins. An explicit empty value supports isolated planning
and overlay construction; it does not relax the supported invocation's inherited PATH/HOME policy.
The native capture graph controls run in a separate process with a complete synthetic environment.

Native ephemeral Kubernetes clients retain the same original use/file scopes and captured home or
EKS projection. String and byte environments share one exact credential-key inventory; filtering
native keys never decodes their values or truncates Unicode keys into ASCII credential names.

**Forbidden patterns:**

- Constructing an `aws`/`kubectl`/`redis-cli` subprocess environment from an empty or
  literal-only list that omits `PATH` and `HOME`.
- A second, parallel "AWS CLI environment" builder. Compatibility adapters that still spawn the
  AWS CLI call `awsCliSubprocessEnvironment`; new effects stay behind the admitted Provider/permit
  boundary rather than adding another host builder.

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

`Prodbox.Http.Client` owns the default process-wide TLS `Manager` (`sharedTlsManager`), constructed
exactly once through the `unsafePerformIO` + `{-# NOINLINE #-}` idiom. `http-client` `Manager`s are
designed for concurrent reuse and pool connections per host, so a single shared manager is both
correct and the point: counterexample `LCPC-2026-07-11` traced a gateway hot-path CPU driver to the
old per-call `newManager` construction (a fresh TLS context and connection pool on every request).
Never construct a `Manager` per call. Its factory lives in `Prodbox.Http.Client`, outside
every daemon-runtime module (where module-level mutable state is forbidden), with fixed settings.
The cached renewable Vault Kubernetes-auth session
(`Prodbox.Vault.Session`) rides on the same shared manager and is documented in
[vault_doctrine.md § 12.1](./vault_doctrine.md).

The manager disables automatic request replay after a reused connection loses its response.
That failure remains observable even when the server already received the request; the owning
interpreter decides whether and how to observe or retry it. Connection pooling remains shared.

The bounded client also offers `httpRequestRawBoundedNoIdle` through a separate process-wide
manager with zero idle capacity. This is for ephemeral endpoints whose completed connections
should be released rather than retained under historical endpoint keys. It shares the existing
wire, header, body, redirect, retry and timeout policy. The pinned pool closes a released
connection without inserting a key; it does not bound active request concurrency. The zero-idle
manager defers the original SDK TLS/proxy factories until TLS is used and caches their pair once
per process. Plain HTTP does not initialize those contexts or read their certificate bundle.
The pinned proxy-factory selector comes from `Network.HTTP.Client.Internal`; the native vehicle
also observes an actual ClientHello. Its manager,
reaper and TLS/native state still require funding and process-lifetime ownership. The SDK timeout
bounds response headers; an owned caller wraps the entire request with its original outer
deadline. `closeManager` is a no-op in the pinned SDK, not a joined release boundary. Native
completion, refusal, cancellation and default-pool compatibility controls live in
`test/qualification/HttpReleasedConnections.hs`.
Bounded protocol requests additionally set a zero redirect allowance and return the first response
under their body ceiling. Their fixed endpoint and request allowance cannot silently expand through
a redirect. General HTTP requests retain their redirect policy. The native exchange counterprogram
and `HttpClientExchangePolicy` suite cover direct success, GET/POST redirects, Vault login and
reply loss on a reused connection under the original caller envelope.
The frozen source, shared counterprogram, exact request observations and replacement records are
preserved in `test/qualification/HOST-BOUNDED-HTTP-EXCHANGE-POLICY-2026-10-28.json`.

### Native SigV4 object-store client (Sprint 1.66)

`Prodbox.Aws.SigV4` implements the pure, byte-exact AWS Signature Version 4 algorithm (canonical
request, string-to-sign, HMAC signing-key chain, and authorization header), unit-tested against
published AWS vectors. `Prodbox.Minio.ObjectStoreNative` builds on it and the shared TLS `Manager`
to perform every Model-B object-store operation (get/put/conditional-put/list/head/create/delete)
as an in-memory, SigV4-signed S3 request — **no `aws` CLI subprocess and no per-operation temp-file
bodies** (the third gateway hot-path CPU driver from counterexample `LCPC-2026-07-11`). Bodies are
held in memory as strict `ByteString`s; the `x-amz-content-sha256` header binds the exact body, and
ETag conditional semantics (`If-Match`/`If-None-Match`) preserve the compare-and-swap outcome
taxonomy (`ConditionalPutConflict` on a `412`, [positive absence](./lifecycle_reconciliation_doctrine.md#30-positive-absence) on a `404`).

The native and subprocess clients are drop-in interchangeable through the `ObjectStoreBackend`
selector in `Prodbox.Minio.ObjectStore` (`objectStoreBackend`); the subprocess path remains the
default and config-selectable rollback until the native client's live-MinIO parity is proven, then
it is deleted through the legacy ledger. The signing algebra is pure and testable; the live parity is
a Standard-O live-proof axis.

### Native SigV4 AWS service clients (Sprint 1.62)

The IAM, STS, Route 53, and Service Quotas clients follow the same pattern — **no `amazonka`, no new
dependency**. `Prodbox.Aws.Native.Wire` hoists one shared signer over `Prodbox.Aws.SigV4` (with the
signed header set folding in `x-amz-security-token`, `content-type`, and `x-amz-target`), a
`NativeAwsSender` send seam (the sole toucher of the shared TLS `Manager`, injectable so fake
protocol servers drive the true sign→classify pipeline pre-cluster), and the `AwsClientError`
outcome classifier. Each service module (`Prodbox.Aws.Native.{Sts,Iam,Route53,ServiceQuotas}`)
exposes a **closed record of operations** built by `mk*Client handle sender`, so a fake record drives
tests; XML responses are hand-parsed via `Prodbox.Aws.Native.Xml` (the `ObjectStoreNative` substring
extractor) and JSON via `aeson`.

Two disciplines are load-bearing:

- **Credentials are a validated linear handle**, `Prodbox.Aws.CredentialHandle`: phantom-indexed by
  origin (`'OriginBase`/`'OriginAssumedRole`), unserializable, redacting every secret on `Show`,
  with no exported base→session widening — a base handle becomes a session handle only through a real
  (or fake) STS round trip, so `sts:AssumeRole`'s temporary session is a *distinct* handle at the
  type level. Native clients take the handle as an argument and never read the `aws` CLI, profiles,
  temp files, or Pod credential env; a source-scan unit test enforces the absence of every such seam.
- **A mutation whose outcome is unconfirmed is never a false success.** `classifyOutcome` maps a
  transport failure on the one `Mutating` op (`iam:CreateAccessKey`) whose bytes may have reached AWS
  to `AwsAmbiguousOutcome`, and a 2xx whose one-time secret cannot be parsed likewise — the consumer
  runs its reconcile (list/delete the orphaned key, re-mint), never a blind retry. Unknown dispatch
  phases default to `PossiblySent` (the safe direction). All other ops are `Idempotent`. Live SigV4
  parity against real AWS is a Standard-O axis carried by the Phase 2/4 consumers.

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
    , retryPolicyJitterFraction :: JitterFraction
    }
    deriving (Eq, Show)

mkRetryPolicy
    :: Int -> Int -> Int -> Int -> JitterFraction
    -> Either RetryPolicyError RetryPolicy
```

**The constructor is hidden (Sprint `1.77`).** A schedule is either one of the named compiled
values in `Prodbox.Retry` — `componentReadinessRetryPolicy`, `helmTransientRetryPolicy`,
`customImagePushRetryPolicy`, `daemonRestartBridgeRetryPolicy`,
`registryReferenceObservationRetryPolicy`,
`perconaPatroniClaimRetryPolicy`, `patroniClusterReadyRetryPolicy`, `daemonWorkerRetryPolicy` —
or the result of `mkRetryPolicy`, which rejects a non-positive attempt budget, a negative delay, a
multiplier below one, a ceiling below the base, and a jitter fraction outside `(0, 1]`. That is
Sprint `1.13` validation item 2 (*"the retry surface is consumed only through the `RetryPolicy`
API"*) restated as a rule that fails: it named no lint, no gate, and no scan, so nothing could
check it.

**Every delay is jittered.** Before Sprint `1.77` no jitter existed anywhere in the tree, so N
clients failing against one dependency retried in permanent lockstep and re-collided on every
attempt. `retryDelayMicros` remains the pure authored schedule; production callers draw through
`drawRetryDelayMicros`, which samples the system CSPRNG and applies the fraction. Jitter only ever
**subtracts**, so a delay lands in `[scheduled * (1 - fraction), scheduled]` and an attempt budget
computed against the authored schedule remains an upper bound. `prodbox dev check` fails any
production module that names the un-jittered `retryDelayMicros` or imports `RetryPolicy (..)`.

### Two distinct retry shapes — keep them separate

There are two callers of `retryDelayMicros`, and they answer different questions. Sprint 1.30
keeps these split rather than collapsing them into one loop:

- **The retrier** (`retryAppError` in `Retry.hs`, `retryServiceAction` /
  `retryIdempotentServiceAction` in `Service.hs`) re-runs a *failing* action while its error
  permits repetition. Both stop as soon as the action succeeds or the error forbids repetition, and
  are bounded by `retryPolicyMaxAttempts`.

  **Retryability is a property of the (operation, error) pair, not of the error (Sprint `1.77`).**
  Permanent-versus-transient is the wrong axis for a mutation: a timeout or dropped connection on a
  mutating call is *indeterminate* — the effect may have been applied and only the response lost.
  `serviceErrorDisposition` therefore returns `FailurePermanent`, `FailureTransient`, or
  `FailureIndeterminate`. `retryServiceAction` repeats only `FailureTransient` outcomes, which
  certainly did not apply. `retryIdempotentServiceAction` also repeats `FailureIndeterminate`, and
  it takes an `IdempotentOperation` — a hidden-constructor wrapper — so repeating a non-idempotent
  operation after an indeterminate outcome does not type-check rather than being forbidden by a
  comment. Note the correction this makes to the previous default: an unclassified failure
  (`SEInternalError`) used to be documented as *"treated as retryable ... the conservative
  default"*, which for a mutation is the least safe reading available; it is now indeterminate.
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

A sibling in the same opaque-proof family widens the pattern past a single role's heap.
`Prodbox.Capacity.Derivation` is the sole bridge from workload proof inputs to a deployable
`ResourceEnvelope`: runtime memory and durable/scratch storage are structural projections, while
service demand consumes a provenance-bound calibrated coefficient and exact ratio arithmetic.
Neither Dhall nor a measurement artifact can directly author request/limit values.

`Prodbox.Capacity.Allocation` carries the current host/cluster/workload nesting as an
opaque, proof-carrying `AllocatedResourcePlan (c :: Certification)`, built by the total smart constructor
`compileResourcePlan` alongside the sibling opaque proofs `ServiceCapacityPlan` and `RuntimeMemoryPlan`:
an over-committed plan is not a constructible value (a `Left`, never a value), the plan and its
`HostCapacity`/`ClusterBudget`/`WorkloadAllocation`/`CertifiedWorkload` components hide their
constructors, and a non-saturating `resourceVectorSubtractChecked` replaces the saturating budget
subtraction (`boundedMinus`) on the budget path so an underflow returns `Left` rather than clamping to
zero. A `GuaranteedEnvelope`/`mkGuaranteedEnvelope` witness proves `request == limit`, tagged by a
`WorkloadQoS` (`Guaranteed | Burstable`) so a workload that must be Guaranteed cannot be authored
`Burstable` (Sprint `1.70` wiring), and a per-workload `WorkloadCertification` phantom-indexes the
plan (`Certified` iff every workload certifies against a committed measured profile). This keeps the
honest split — memory sufficiency is already structural via `RuntimeMemoryPlan`, while CPU sufficiency
stays an `uncertified-until-first-profile` measured seam.

The [Development Plan](../../DEVELOPMENT_PLAN/README.md) sequences and carries status for the rest of
the family; each item below is a forward reference, not a landed claim. The proof is threaded onto
`ValidatedSettings` as the required `validatedAllocatedPlan` field — the **decode gate**, where no
proof means no validated settings and therefore no renderer input (Sprint `1.69`). Read "not a
constructible value" with its region attached: it holds over the modules the gate compiles, and it
ends wherever the value is written back out as text — see "The region of Ring 2" in
[resource_scaling_doctrine.md § 2C](./resource_scaling_doctrine.md) and
[chaos_hardening_doctrine.md § 23](./chaos_hardening_doctrine.md).
`Prodbox.Capacity.Render` is the one shared `ResourceQuota`/`LimitRange`/runtime-vector renderer that
consumes the proof (Sprint `3.28`). `Prodbox.Capacity.Placement` owns `renderedNamespace`,
`planNamespaceQuota`, and the `WorkloadConcurrency` (`Steady | ExclusiveWindow`) that makes namespace
quotas derived from workload draws rather than authored (Sprint `3.27`), with each durable PVC sized
from the workload's one `durable_storage_mib` source that simultaneously sizes the quota and the fit
proof (Sprint `3.29`). `Prodbox.Capacity.ObservedHost` carries the dual-device observed-host root plus
`compileResourcePlanAgainstObserved`, re-proving `cluster <= host` against the machine discovered at
reconcile across distinct durable and ephemeral devices (Sprint `4.52`). The over-commit algebra and
the honest three-ring boundary are owned by
[resource_scaling_doctrine.md § 2A–§2C](./resource_scaling_doctrine.md#2a-resource-requirements-are-mandatory-and-capped).

`Prodbox.Capacity.Config.runtimeMemoryPlanForProfile` supplies the compiled memory input used to
derive the matching workload contract; the resulting cgroup memory limit is a projection rather
than a second authored value. The validator rejects unbounded or malformed child schedules. Capacity one uses
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

The pre-cutover legacy Gateway liveness worker is intentionally outside the subprocess/child
scheduler: it consumes a committed signed semantic heartbeat as its process-local fence, then
overwrites one verified `SignedLivenessFrame` per bounded member in STM and peer transport. The
frame type cannot express a claim or yield; its outer HMAC covers the complete signed boot
heartbeat, and receiver verification re-enters exact Orders, both event-key checks, the derived
boot fence, compacted-cursor position, sequence, timestamp, and skew constructors. A recurring
liveness tick must not call the legacy Model-B interpreter, spawn a child, or loosen the Orders
timeout. The distinct supervised backend-proof worker may cross the existing Model-B transaction
on its 60-second cadence, commit a normal semantic heartbeat, and replace the local liveness
session; it is not part of the recurring liveness tick.

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
registry, shutdown signal, hot-reloadable live config). Their terminal lifecycle state is private
and proof-carrying: timeout is an observation, never evidence that child ownership ended. See
[distributed_gateway_architecture.md → Daemon Lifecycle → The Env record grows](./distributed_gateway_architecture.md#daemon-lifecycle).

## Cross-References

- [Code Quality Doctrine](./code_quality.md)
- [Pure FP Standards](./pure_fp_standards.md)
- [Dependency Management](./dependency_management.md)
- [Resource Scaling Doctrine](./resource_scaling_doctrine.md)
- [Development Plan](../../DEVELOPMENT_PLAN/README.md)
