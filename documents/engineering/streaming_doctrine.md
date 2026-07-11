# Streaming Doctrine

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: DEVELOPMENT_PLAN/phase-2-gateway-dns.md, documents/engineering/README.md, documents/engineering/distributed_gateway_architecture.md, documents/engineering/effect_interpreter.md, documents/engineering/unit_testing_policy.md, documents/engineering/pulsar_messaging_doctrine.md
**Generated sections**: none

> **Purpose**: Define streaming and terminal-record invariants for supported `prodbox` command
> flows.

## 1. Streaming Contract Statement

Operator-facing progress output is part of the supported command contract.

- phase banners must appear in a stable order
- command output must be line-oriented and readable in a normal terminal
- prerequisite and validation phases must not hide major control-flow transitions

## 2. Invariant

Streaming output should preserve the causal story of what the command is doing.

- emit phase boundaries before the work they describe
- do not collapse multiple major phases into one ambiguous line
- preserve stderr for underlying tool failures when that context is operator-relevant

## 3. Scope and Orthogonality

This doctrine applies to user-facing command output. It does not replace:

- prerequisite doctrine
- DAG construction doctrine
- validation ownership doctrine

## 4. Runtime Expectations

`src/Prodbox/TestRunner.hs` is the most visible implementation of this doctrine.

It emits:

- `Phase 1/2` prerequisite banners
- optional `Phase 1.5/2` runbook banners
- `Phase 1.6/2` or post-test runtime restoration banners when the selected suite requires them
- `Phase 2/2` before Haskell suites or named validation payloads run

## 5. Terminal Record Contract

Terminal records must remain legible and attributable.

- each phase banner is its own stdout line
- user-facing summaries should be emitted before a command exits successfully
- hard failures should preserve the underlying error context where possible
- subprocess-driven output should construct commands as structured values in
  `src/Prodbox/Subprocess.hs`, execute them through `runStreaming` or `capture`, and render
  operator-facing command identity through `renderSubprocess` rather than by concatenating
  ad-hoc shell strings at each call site

## 6. Lifecycle Destructive Success-Versus-Failure Rule

`prodbox cluster delete --yes` is the canonical case of a destructive lifecycle command that wraps a
noisy upstream uninstaller. Its operator-facing output rule splits cleanly along the exit code of
`/usr/local/bin/rke2-uninstall.sh`:

- Success path: `deleteRke2ClusterSubstrate` captures the uninstaller's stdout and stderr through
  the lifecycle-local quiet path (`captureToolOutput`) and emits only the doctrine-owned summary
  lines — `Deleting local RKE2 environment...`, AWS destroy dispositions,
  `Local RKE2 substrate: cleanup complete`, the kubeconfig disposition, and the retained-root
  notice. Benign upstream chatter that the uninstaller writes to its **own** stdout/stderr —
  `Cannot find device "cni0"`, `semodule: not found`, and `Cleanup completed successfully` — does
  not reach the operator terminal, because `captureToolOutput` swallows those streams on success.
  The inotify warning `Failed to allocate directory watch: Too many open files` was historically
  the one exception: the systemd manager (PID 1) / journald emits it **out-of-band to the console**,
  not through the uninstaller's captured fds, so `captureToolOutput` cannot intercept it. The root
  cause — the kernel default `fs.inotify.max_user_instances = 128` being exhausted by RKE2 +
  containerd + kubelet (all uid 0) during teardown — is now fixed at its source: both
  `prodbox cluster reconcile` and `prodbox cluster delete` run `ensureHostInotifyLimits` as their first
  host-prep step, which idempotently persists a `/etc/sysctl.d/99-prodbox-inotify.conf` drop-in
  (`max_user_instances = 8192`, `max_user_watches = 1048576`) and applies it via `sysctl --system`
  **before** systemd unwinds the RKE2 units. With the limit raised, PID 1 never hits `EMFILE` and
  the line is not emitted. The `isIgnorableRke2DeleteNoiseLine` classification below is retained
  only as defense-in-depth for the transient window on a host that has never run the host-prep
  step; the line, if it ever appears, stays benign (teardown still succeeds).
- Failure path: when the uninstaller exits non-zero, `summarizeRke2DeleteFailure` keeps the last
  actionable lines from stdout and stderr (filtered through `isIgnorableRke2DeleteNoiseLine` so
  the benign classes above stay out of the summary — the directory-watch line only reaches that
  filter on the rare path where systemd routes it to the uninstaller's stderr; its usual
  out-of-band console emission is never in the captured streams) and renders them through the `writeError`
  boundary so the operator sees the failing command identity.

This rule is scoped to `prodbox cluster delete --yes`. It does not extend to repo-wide stderr
suppression, and other lifecycle commands continue to follow the streaming contract above.

## 7. Intent Ownership

This SSoT co-owns streaming doctrine intention.

- Owned statement: operator-facing phase and validation output is part of the supported command
  contract.
- Linked dependents: `src/Prodbox/TestRunner.hs`, `src/Prodbox/Subprocess.hs`,
  `src/Prodbox/EffectInterpreter.hs`, `test/unit/Main.hs`.

## Output Rules

Short-running CLI invocations use `stdout` for primary output:

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

These rules apply to short-running invocations. Long-running daemons follow
the structured-logging discipline in
[distributed_gateway_architecture.md → Daemon Lifecycle → Logging and observability](./distributed_gateway_architecture.md#daemon-lifecycle):
stderr receives JSON-formatted log lines; stdout is reserved for the
daemon's protocol surface or unused; `--format` and `--color` flags do not
apply.

### Sealed-State Output Redaction and the Exists-Versus-Absent Oracle

Operator-facing output is one of the four surfaces governed by the
whole-system zero-child-info invariant: when the parent cluster's Vault is
sealed, no stdout, stderr, or structured-log line may reveal whether a child
or stack exists, how many there are, where they live, or what they are named.
Two output rules implement that invariant; both are owned by
[vault_doctrine.md](./vault_doctrine.md) and restated here only as the
streaming-side contract.

- **No sensitive name in logs or output.** Output never emits a
  child-cluster name, a Pulumi stack identity (`aws-eks`, `aws-test`, …), a
  MinIO object key, a role-revealing bucket name, a Vault token, or recovered
  object plaintext on a sealed-state path. Diagnostics use redacted
  structured lines (`vault_status=sealed component=pulumi operation=preview
  result=blocked`) rather than identifying messages such as `Cannot deploy
  downstream cluster prod-eu-west-1 …`. Opaque-id and token types render
  through a redacted `Show`, so an identifier can never reach a log site in
  cleartext. This is the streaming-side restatement of
  [vault_doctrine.md §14 — Error model and logging](./vault_doctrine.md#14-error-model-and-logging).
- **No exists-versus-`NoSuchKey` oracle.** A residue, listing, or stack-output
  query must not let the difference between "object/stack present" and
  "absent" leak across the output boundary while Vault is sealed. The success
  message, the error message, and the exit code for "stack found" and "stack
  not found" must be indistinguishable on a sealed path — an `aws s3api`
  `NoSuchKey` discriminator or a `pulumi stack ls` membership check that
  surfaces a distinguishable line is itself a metadata leak. Residue and
  listing queries are gated behind the Vault-readiness check before they emit
  any per-object disposition. The object-store layout that makes this
  enforceable — one generically-named bucket holding only opaque
  `objects/<id>.enc` at a decoy-padded constant count — is owned by
  [vault_doctrine.md §9 — MinIO as a ciphertext store](./vault_doctrine.md#9-minio-as-a-ciphertext-store).

These two rules are scoped to sealed-state paths; ordinary unsealed-Vault
operation streams the causal story per the contract above. Sprint `4.33` has
landed the Haskell-side residue/listing gate and redacted token rendering; the
live cross-surface red-team proof is exercised by the sealed-Vault validation
in Sprint `5.8`.

## At-Least-Once Event Processing

Event-driven systems require idempotent handlers and explicit delivery
tracking. Events are immutable records stored with timestamps; a
`processed_at` column tracks which events have been handled.

`Prodbox.Daemon.Events` (`src/Prodbox/Daemon/Events.hs`) is the reference
at-least-once port: `recordEvent` is insert-once by `eventId`,
`fetchUnprocessedEvents` returns the `processed_at IS NULL` set in
`created_at ASC` order, and `markEventProcessed` is the first-write-wins
marker. Gateway peer gossip (`src/Prodbox/Gateway/Peer.hs`) is a deliberately different,
**non-durable bounded anti-entropy** protocol: peers exchange bounded cursor deltas and use a
signed per-emitter semantic checkpoint plus bounded contiguous suffix when a cursor falls outside
the replay window. Duplicate frames are absorbed by an idempotent semantic fold, but the gateway
does not retain a durable work history or carry the `processed_at` delivery guarantee.

Do not conflate the two. Durable consumers retain immutable records according to their topic/store
retention policy and use explicit processing acknowledgements. The gateway retains only bounded hot
coordination state and bounded replay/diagnostic windows; sending or retaining the complete
process-lifetime peer history is not required by at-least-once delivery. Sprint `2.31` landed this
bounded gateway protocol without changing the durable event-store contract.

The durable event **payload** is canonical CBOR project-wide per
[pulsar_messaging_doctrine.md](./pulsar_messaging_doctrine.md). The
idempotent-handler and first-write-wins delivery semantics this section owns are unchanged.

### Event storage

```haskell
data EventType
    = OrderCreated
    | OrderSubmitted
    | OrderApproved
    | OrderFulfilled
    | OrderCancelled
    deriving stock (Show, Eq, Generic)
    deriving anyclass (Serialise)

data StoredEvent = StoredEvent
    { eventId :: UUID
    , eventAggregateId :: UUID
    , eventType :: EventType
    , eventPayload :: CborPayload
    , eventCreatedAt :: UTCTime
    , eventProcessedAt :: Maybe UTCTime
    }
    deriving stock (Show, Eq, Generic)
```

### Recording and marking events

```haskell
recordEvent :: Connection -> UUID -> EventType -> CborPayload -> IO ()
recordEvent conn aggregateId eventType payload = do
    _ <- execute conn
        "INSERT INTO domain_events \
        \(aggregate_id, event_type, payload, created_at) \
        \VALUES (?, ?, ?, clock_timestamp())"
        (aggregateId, show eventType, cborPayloadBytes payload)
    pure ()

markEventProcessed :: Connection -> UUID -> IO ()
markEventProcessed conn eventId = do
    _ <- execute conn
        "UPDATE domain_events \
        \SET processed_at = clock_timestamp() \
        \WHERE id = ? AND processed_at IS NULL"
        [eventId]
    pure ()

fetchUnprocessedEvents :: Connection -> IO [StoredEvent]
fetchUnprocessedEvents conn =
    query conn
        "SELECT id, aggregate_id, event_type, payload, created_at, processed_at \
        \FROM domain_events \
        \WHERE processed_at IS NULL \
        \ORDER BY created_at ASC"
        ()
```

The `markEventProcessed` `AND processed_at IS NULL` clause is an authoritative,
load-bearing guard, not an optimization: it makes marking an event **first-write-wins**.
The earliest writer stamps `processed_at`; every later redelivery of the same event
finds the row already non-NULL and the `UPDATE` affects zero rows, so a single
`clock_timestamp()` is recorded for the event no matter how many times the handler
runs. Removing the clause would let a redelivery overwrite the original processing
timestamp and corrupt the delivery-state audit trail. The guard must stay in any
implementation of this port.

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

processEvents :: Connection -> EventHandler -> IO ()
processEvents conn handler = do
    events <- fetchUnprocessedEvents conn
    for_ events $ \event -> do
        handler event  -- MUST be idempotent
        markEventProcessed conn (eventId event)
```

**Forbidden patterns:**

- Event handlers with non-idempotent side effects (sending emails, charging
  cards) without deduplication.
- Events stored without creation timestamps.
- Missing `processed_at` column (no way to track delivery state).
- Marking an event processed without the `AND processed_at IS NULL` first-write-wins
  guard (a redelivery would overwrite the original processing timestamp).
- Event ordering other than `created_at ASC` (breaks replay semantics).
- Deleting events after processing (audit trail loss).

## Cross-References

- [Unit Testing Policy](./unit_testing_policy.md)
- [Effect Interpreter Runtime Contract](./effect_interpreter.md)
- [CLI Command Surface § 2A — Operator Vocabulary Contract](./cli_command_surface.md#2a-operator-vocabulary-contract)
  — every string this doctrine governs (stdout/stderr phase banners,
  refusal messages, success summaries) must use operator vocabulary,
  not development-plan tracking identifiers.
