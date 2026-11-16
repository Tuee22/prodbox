# Output and Event Processing

**Status**: Authoritative source
**Supersedes**: Pre-refactor streaming/output doctrine
**Generated sections**: none
**Applicability**: Accepted target runtime contract, activated by the numerical implementation phases.

> **Purpose**: Keep operator output honest and event handling idempotent without duplicating lifecycle ownership.

## Operator and machine output

[CLI results](cli_command_surface.md#results-and-recovery) owns the outcome vocabulary. Human output states selected scope, observed facts, work, result and one remedy. JSON carries structured outcome/context/operation/observation bindings. A source observation that failed remains unavailable; a successful renderer or exited process cannot turn it into a Clean result.

Keep stdout suitable for the selected output format. Bounded diagnostics and progress are distinct from the terminal record. Stream events in actual causal order, distinguish root failure from downstream blockers, and preserve primary and cleanup outcomes separately. Do not emit a success banner before independent closing observations.

Identifiers needed by the authenticated operator may appear as non-secret lifecycle metadata under the accepted policy. Credentials, secret bytes, private config payloads and raw secret hashes never enter progress, errors, reports or shell commands. Bounded redaction is type/field based; do not assume truncation removes secrets.

## Event semantics

Gateway/Pulsar/application protocols use the declared typed codec, canonical ordering and stable event/operation identities. Preserve the actual retained CBOR protocol where applicable; machine CLI JSON is a separate output surface, not a second event protocol.

Delivery is at least once. Consumers use durable identity/version checks so duplicates are idempotent, stale generations do not overwrite newer state, and applied-without-response is recovered from authoritative observations. Preserve original event bytes/commit identity where the continuity protocol requires replay. A checkpoint/cursor is not evidence that an unrelated provider resource disappeared.

Bound queues, frames, retained replay history, retries and subprocess output within the admitted operation/resource budget. Backpressure and cancellation propagate through owned scopes. Losing a client must not silently admit a successor while a worker can still act. [Lifecycle](lifecycle.md) owns worker settlement and [gateway/messaging](gateway_and_messaging.md) owns emitter continuity.

## Validation

Exercise actual protocol requests, duplicates, response loss, restart, bounded load, cancellation and redaction. Verify required observations through independent clients. Source mutation cases must detect unconditional success/clean projection, dropped ownership/version checks and premature report/credential retirement. [Testing](testing.md)
